{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE ViewPatterns          #-}

-- | Provides code actions to add missing pragmas (whenever GHC suggests to)
module Ide.Plugin.Pragmas
  ( suggestPragmaDescriptor
  , completionDescriptor
  , suggestDisableWarningDescriptor
  -- For testing
  , validPragmas
  , AppearWhere(..)
  ) where

import           Control.Lens                       hiding (List)
import           Control.Monad.IO.Class             (MonadIO (liftIO))
import           Control.Monad.Trans.Class          (lift)
import           Data.List.Extra                    (nubOrdOn)
import qualified Data.Map                           as M
import           Data.Maybe                         (catMaybes)
import qualified Data.Text                          as T
import           Development.IDE
import           Development.IDE.Core.Compile       (sourceParser,
                                                     sourceTypecheck)
import           Development.IDE.Core.PluginUtils
import           Development.IDE.GHC.Compat
import           Development.IDE.Plugin.Completions (ghcideCompletionsPluginPriority)
import qualified Development.IDE.Spans.Pragmas      as Pragmas
import           Ide.Plugin.Error
import           Ide.Types
import qualified Language.LSP.Protocol.Lens         as L
import qualified Language.LSP.Protocol.Message      as LSP
import qualified Language.LSP.Protocol.Types        as LSP
import qualified Language.LSP.Server                as LSP
import qualified Language.LSP.VFS                   as VFS
import qualified Text.Fuzzy                         as Fuzzy

-- ---------------------------------------------------------------------

suggestPragmaDescriptor :: PluginId -> PluginDescriptor IdeState
suggestPragmaDescriptor plId = (defaultPluginDescriptor plId)
  { pluginHandlers = mkPluginHandler LSP.SMethod_TextDocumentCodeAction suggestPragmaProvider
  , pluginPriority = defaultPluginPriority + 1000
  }

completionDescriptor :: PluginId -> PluginDescriptor IdeState
completionDescriptor plId = (defaultPluginDescriptor plId)
  { pluginHandlers = mkPluginHandler LSP.SMethod_TextDocumentCompletion completion
  , pluginPriority = ghcideCompletionsPluginPriority + 1
  }

suggestDisableWarningDescriptor :: PluginId -> PluginDescriptor IdeState
suggestDisableWarningDescriptor plId = (defaultPluginDescriptor plId)
  { pluginHandlers = mkPluginHandler LSP.SMethod_TextDocumentCodeAction suggestDisableWarningProvider
    -- #3636 Suggestions to disable warnings should appear last.
  , pluginPriority = 0
  }

-- ---------------------------------------------------------------------
-- | Title and pragma
type PragmaEdit = (T.Text, Pragma)

data Pragma = LangExt T.Text | OptGHC T.Text
  deriving (Show, Eq, Ord)

suggestPragmaProvider :: PluginMethodHandler IdeState 'LSP.Method_TextDocumentCodeAction
suggestPragmaProvider = mkCodeActionProvider suggest

suggestDisableWarningProvider :: PluginMethodHandler IdeState 'LSP.Method_TextDocumentCodeAction
suggestDisableWarningProvider = mkCodeActionProvider $ const suggestDisableWarning

mkCodeActionProvider :: (Maybe DynFlags -> Diagnostic -> [PragmaEdit]) -> PluginMethodHandler IdeState 'LSP.Method_TextDocumentCodeAction
mkCodeActionProvider mkSuggest state _plId
  (LSP.CodeActionParams _ _ LSP.TextDocumentIdentifier{ _uri = uri } _ (LSP.CodeActionContext diags _monly _)) = do
    normalizedFilePath <- getNormalizedFilePathE uri
    -- ghc session to get some dynflags even if module isn't parsed
    (hscEnv -> hsc_dflags -> sessionDynFlags, _) <-
      runActionE "Pragmas.GhcSession" state $ useWithStaleE GhcSession normalizedFilePath
    (_, fileContents) <- liftIO $ runAction "Pragmas.GetFileContents" state $ getFileContents normalizedFilePath
    parsedModule <- liftIO $ runAction "Pragmas.GetParsedModule" state $ getParsedModule normalizedFilePath
    let parsedModuleDynFlags = ms_hspp_opts . pm_mod_summary <$> parsedModule
        nextPragmaInfo = Pragmas.getNextPragmaInfo sessionDynFlags fileContents
        pedits = (nubOrdOn snd . concat $ mkSuggest parsedModuleDynFlags <$> diags)
    pure  $ LSP.InL $ pragmaEditToAction uri nextPragmaInfo <$> pedits



-- | Add a Pragma to the given URI at the top of the file.
-- It is assumed that the pragma name is a valid pragma,
-- thus, not validated.
pragmaEditToAction :: Uri -> Pragmas.NextPragmaInfo -> PragmaEdit -> (LSP.Command LSP.|? LSP.CodeAction)
pragmaEditToAction uri Pragmas.NextPragmaInfo{ nextPragmaLine, lineSplitTextEdits } (title, p) =
  LSP.InR $ LSP.CodeAction title (Just LSP.CodeActionKind_QuickFix) (Just []) Nothing Nothing (Just edit) Nothing Nothing
  where
    render (OptGHC x)  = "{-# OPTIONS_GHC -Wno-" <> x <> " #-}\n"
    render (LangExt x) = "{-# LANGUAGE " <> x <> " #-}\n"
    pragmaInsertPosition = Position (fromIntegral nextPragmaLine) 0
    pragmaInsertRange = Range pragmaInsertPosition pragmaInsertPosition
    -- workaround the fact that for some reason lsp-test applies text
    -- edits in reverse order than lsp (tried in both coc.nvim and vscode)
    textEdits =
      if | Just (Pragmas.LineSplitTextEdits insertTextEdit deleteTextEdit) <- lineSplitTextEdits
         , let LSP.TextEdit{ _range, _newText } = insertTextEdit ->
             [LSP.TextEdit _range (render p <> _newText), deleteTextEdit]
         | otherwise -> [LSP.TextEdit pragmaInsertRange (render p)]

    edit =
      LSP.WorkspaceEdit
        (Just $ M.singleton uri textEdits)
        Nothing
        Nothing

suggest :: Maybe DynFlags -> Diagnostic -> [PragmaEdit]
suggest dflags diag =
  suggestAddPragma dflags diag

-- ---------------------------------------------------------------------

suggestDisableWarning :: Diagnostic -> [PragmaEdit]
suggestDisableWarning Diagnostic {_code}
  | Just (LSP.InR (T.stripPrefix "-W" -> Just w)) <- _code
  , w `notElem` warningBlacklist =
    pure ("Disable \"" <> w <> "\" warnings", OptGHC w)
  | otherwise = []

-- Don't suggest disabling type errors as a solution to all type errors
warningBlacklist :: [T.Text]
-- warningBlacklist = []
warningBlacklist = ["deferred-type-errors"]

-- ---------------------------------------------------------------------

-- | Offer to add a missing Language Pragma to the top of a file.
-- Pragmas are defined by a curated list of known pragmas, see 'possiblePragmas'.
suggestAddPragma :: Maybe DynFlags -> Diagnostic -> [PragmaEdit]
suggestAddPragma mDynflags Diagnostic {_message, _source}
    | _source == Just sourceTypecheck || _source == Just sourceParser = genPragma _message
  where
    genPragma target =
      [("Add \"" <> r <> "\"", LangExt r) | r <- findPragma target, r `notElem` disabled]
    disabled
      | Just dynFlags <- mDynflags =
        -- GHC does not export 'OnOff', so we have to view it as string
        catMaybes $ T.stripPrefix "Off " . printOutputable <$> extensions dynFlags
      | otherwise =
        -- When the module failed to parse, we don't have access to its
        -- dynFlags. In that case, simply don't disable any pragmas.
        []
suggestAddPragma _ _ = []

-- | Find all Pragmas are an infix of the search term.
findPragma :: T.Text -> [T.Text]
findPragma str = concatMap check possiblePragmas
  where
    check p = [p | T.isInfixOf p str]

    -- We exclude the Strict extension as it causes many false positives, see
    -- the discussion at https://github.com/haskell/ghcide/pull/638
    --
    -- We don't include the No- variants, as GHC never suggests disabling an
    -- extension in an error message.
    possiblePragmas :: [T.Text]
    possiblePragmas =
       [ name
       | FlagSpec{flagSpecName = T.pack -> name} <- xFlags
       , "Strict" /= name
       ]

-- | All language pragmas, including the No- variants
allPragmas :: [T.Text]
allPragmas =
  concat
    [ [name, "No" <> name]
    | FlagSpec{flagSpecName = T.pack -> name} <- xFlags
    ]
  <>
  -- These pragmas are not part of xFlags as they are not reversable
  -- by prepending "No".
  [ -- Safe Haskell
    "Unsafe"
  , "Trustworthy"
  , "Safe"

    -- Language Version Extensions
  , "Haskell98"
  , "Haskell2010"
#if MIN_VERSION_ghc(9,2,0)
  , "GHC2021"
#endif
  ]

-- ---------------------------------------------------------------------
flags :: [T.Text]
flags = map (T.pack . stripLeading '-') $ flagsForCompletion False

completion :: PluginMethodHandler IdeState 'LSP.Method_TextDocumentCompletion
completion _ide _ complParams = do
    let (LSP.TextDocumentIdentifier uri) = complParams ^. L.textDocument
        position = complParams ^. L.position
    contents <- lift $ LSP.getVirtualFile $ toNormalizedUri uri
    fmap (LSP.InL) $ case (contents, uriToFilePath' uri) of
        (Just cnts, Just _path) ->
            result <$> VFS.getCompletionPrefix position cnts
            where
                result (Just pfix)
                    | "{-# language" `T.isPrefixOf` line
                    = map buildCompletion
                        (Fuzzy.simpleFilter (VFS.prefixText pfix) allPragmas)
                    | "{-# options_ghc" `T.isPrefixOf` line
                    =  map buildCompletion
                        (Fuzzy.simpleFilter (VFS.prefixText pfix) flags)
                    | "{-#" `T.isPrefixOf` line
                    = [ mkPragmaCompl (a <> suffix) b c
                      | (a, b, c, w) <- validPragmas, w == NewLine
                      ]
                    | -- Do not suggest any pragmas any of these conditions:
                      -- 1. Current line is a an import
                      -- 2. There is a module name right before the current word.
                      --    Something like `Text.la` shouldn't suggest adding the
                      --    'LANGUAGE' pragma.
                      -- 3. The user has not typed anything yet.
                      "import" `T.isPrefixOf` line || not (T.null module_) || T.null word
                    = []
                    | otherwise
                    = [ mkPragmaCompl (prefix <> pragmaTemplate <> suffix) matcher detail
                      | (pragmaTemplate, matcher, detail, appearWhere) <- validPragmas
                      , -- Only suggest a pragma that needs its own line if the whole line
                        -- fuzzily matches the pragma
                        (appearWhere == NewLine && Fuzzy.test line matcher ) ||
                        -- Only suggest a pragma that appears in the middle of a line when
                        -- the current word is not the only thing in the line and the
                        -- current word fuzzily matches the pragma
                        (appearWhere == CanInline && line /= word && Fuzzy.test word matcher)
                      ]
                    where
                        line = T.toLower $ VFS.fullLine pfix
                        module_ = VFS.prefixModule pfix
                        word = VFS.prefixText pfix
                        -- Not completely correct, may fail if more than one "{-#" exist
                        -- , we can ignore it since it rarely happen.
                        prefix
                            | "{-# "  `T.isInfixOf` line = ""
                            | "{-#"   `T.isInfixOf` line = " "
                            | otherwise                 = "{-# "
                        suffix
                            | " #-}" `T.isSuffixOf` line = ""
                            | "#-}"  `T.isSuffixOf` line = " "
                            | "-}"   `T.isSuffixOf` line = " #"
                            | "}"    `T.isSuffixOf` line = " #-"
                            | otherwise                 = " #-}"
                result Nothing = []
        _ -> return $ []

-----------------------------------------------------------------------

-- | Pragma where exist
data AppearWhere =
  NewLine
  -- ^Must be on a new line
  | CanInline
  -- ^Can appear in the line
  deriving (Show, Eq)

validPragmas :: [(T.Text, T.Text, T.Text, AppearWhere)]
validPragmas =
  [ ("LANGUAGE ${1:extension}"        , "LANGUAGE"         , "{-# LANGUAGE #-}"         ,   NewLine)
  , ("OPTIONS_GHC -${1:option}"       , "OPTIONS_GHC"      , "{-# OPTIONS_GHC #-}"      ,   NewLine)
  , ("INLINE ${1:function}"           , "INLINE"           , "{-# INLINE #-}"           ,   NewLine)
  , ("NOINLINE ${1:function}"         , "NOINLINE"         , "{-# NOINLINE #-}"         ,   NewLine)
  , ("INLINABLE ${1:function}"        , "INLINABLE"        , "{-# INLINABLE #-}"        ,   NewLine)
  , ("WARNING ${1:message}"           , "WARNING"          , "{-# WARNING #-}"          , CanInline)
  , ("DEPRECATED ${1:message}"        , "DEPRECATED"       , "{-# DEPRECATED  #-}"      , CanInline)
  , ("ANN ${1:annotation}"            , "ANN"              , "{-# ANN #-}"              ,   NewLine)
  , ("RULES"                          , "RULES"            , "{-# RULES #-}"            ,   NewLine)
  , ("SPECIALIZE ${1:function}"       , "SPECIALIZE"       , "{-# SPECIALIZE #-}"       ,   NewLine)
  , ("SPECIALIZE INLINE ${1:function}", "SPECIALIZE INLINE", "{-# SPECIALIZE INLINE #-}",   NewLine)
  , ("SPECIALISE ${1:function}"       , "SPECIALISE"       , "{-# SPECIALISE #-}"       ,   NewLine)
  , ("SPECIALISE INLINE ${1:function}", "SPECIALISE INLINE", "{-# SPECIALISE INLINE #-}",   NewLine)
  , ("MINIMAL ${1:functions}"         , "MINIMAL"          , "{-# MINIMAL #-}"          , CanInline)
  , ("UNPACK"                         , "UNPACK"           , "{-# UNPACK #-}"           , CanInline)
  , ("NOUNPACK"                       , "NOUNPACK"         , "{-# NOUNPACK #-}"         , CanInline)
  , ("COMPLETE ${1:function}"         , "COMPLETE"         , "{-# COMPLETE #-}"         ,   NewLine)
  , ("OVERLAPPING"                    , "OVERLAPPING"      , "{-# OVERLAPPING #-}"      , CanInline)
  , ("OVERLAPPABLE"                   , "OVERLAPPABLE"     , "{-# OVERLAPPABLE #-}"     , CanInline)
  , ("OVERLAPS"                       , "OVERLAPS"         , "{-# OVERLAPS #-}"         , CanInline)
  , ("INCOHERENT"                     , "INCOHERENT"       , "{-# INCOHERENT #-}"       , CanInline)
  ]

mkPragmaCompl :: T.Text -> T.Text -> T.Text -> LSP.CompletionItem
mkPragmaCompl insertText label detail =
  LSP.CompletionItem label Nothing (Just LSP.CompletionItemKind_Keyword) Nothing (Just detail)
    Nothing Nothing Nothing Nothing Nothing (Just insertText) (Just LSP.InsertTextFormat_Snippet)
    Nothing Nothing Nothing Nothing Nothing Nothing Nothing


stripLeading :: Char -> String -> String
stripLeading _ [] = []
stripLeading c (s:ss)
  | s == c = ss
  | otherwise = s:ss


buildCompletion :: T.Text -> LSP.CompletionItem
buildCompletion label =
  LSP.CompletionItem label Nothing (Just LSP.CompletionItemKind_Keyword) Nothing Nothing
    Nothing Nothing Nothing Nothing Nothing Nothing Nothing
    Nothing Nothing Nothing Nothing Nothing Nothing Nothing



