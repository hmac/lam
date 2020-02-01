{-# LANGUAGE DeriveGeneric #-}
module Main where

import           Syn.Print

import           Text.Pretty.Simple             ( pPrint )
import           Data.Text.Prettyprint.Doc.Render.Terminal
import           Data.Text.Prettyprint.Doc
import           System.IO                      ( stdout )

import           ModuleGroup
import           ModuleGroupCompiler            ( CompiledModule(..) )
import qualified ModuleLoader
import qualified ModuleGroupTypechecker
import qualified ModuleGroupCompiler

import qualified Repl                           ( run )
import qualified LC.Print                       ( print )
import           LC.Eval                        ( evalMain )
import           Options.Generic

import           Constraint.Print

data Config =
      Repl
    | Run FilePath
    | Typecheck FilePath
    | Parse FilePath
    | DumpLc FilePath
    | DumpTypeEnv FilePath
    deriving (Generic, Show)

instance ParseRecord Config

-- Parse stdin as a Lam module and pretty print the result
main :: IO ()
main = do
  cfg <- getRecord "lam"
  case cfg of
    Repl          -> Repl.run
    Run         f -> run f
    Parse       f -> parse f
    DumpLc      f -> dumpLC f
    DumpTypeEnv f -> dumpTypeEnv f
    Typecheck   f -> typecheck f

parse :: FilePath -> IO ()
parse = withParsedFile pPrint

dumpLC :: FilePath -> IO ()
dumpLC = withParsedFile $ \g ->
  case ModuleGroupTypechecker.typecheckModuleGroup g of
    Left  err -> printNicely (printError err)
    Right g'  -> pPrint (ModuleGroupCompiler.compileModule g')

dumpTypeEnv :: FilePath -> IO ()
dumpTypeEnv = withParsedFile (pPrint . ModuleGroupTypechecker.dumpEnv)

typecheck :: FilePath -> IO ()
typecheck = withParsedFile $ \g ->
  case ModuleGroupTypechecker.typecheckModuleGroup g of
    Left  err -> printNicely (printError err)
    Right _   -> printNicely "Success."

run :: FilePath -> IO ()
run = withParsedFile $ \g ->
  case ModuleGroupTypechecker.typecheckModuleGroup g of
    Left err -> print (printError err)
    Right g' ->
      let cm     = ModuleGroupCompiler.compileModule g'
          answer = evalMain (cModuleName cm) (cModuleEnv cm)
      in  printNicely (LC.Print.print answer)

withParsedFile :: (UntypedModuleGroup -> IO ()) -> FilePath -> IO ()
withParsedFile cb path = do
  mgroup <- ModuleLoader.loadFromPath path
  case mgroup of
    Left  e -> putStrLn e
    Right g -> cb g

layout :: Document -> SimpleDocStream AnsiStyle
layout doc = reAnnotateS styleToColor (layoutPretty defaultLayoutOptions doc)

printNicely :: Document -> IO ()
printNicely doc = renderIO stdout (layout doc) >> putStrLn ""

-- Conor Colours
-- https://github.com/idris-lang/Idris-dev/blob/master/docs/reference/semantic-highlighting.rst
styleToColor :: Style -> AnsiStyle
styleToColor VarStyle      = color Magenta
styleToColor KeywordStyle  = bold
styleToColor FunctionStyle = color Green
styleToColor TypeStyle     = color Blue
styleToColor DataStyle     = color Red
styleToColor HoleStyle     = color Magenta <> italicized
