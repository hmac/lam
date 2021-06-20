{-# LANGUAGE DuplicateRecordFields #-}
module ModuleGroupCompiler where

-- This module takes a ModuleGroup, compiles each module in it, and somehow
-- merges it all together.

import qualified Chez.Compile                  as Chez
import           Data.Name
import           ModuleGroup
import           Syn.Typed


-- We'll attempt this as follows:
-- All top level declarations will be qualified with their module name.
-- When a module A imports module B, we'll insert top level declarations into A
-- which alias all the declarations in B. This approach should generalise well
-- to import aliases, qualification, hiding etc when we support them.

-- Example:
--
-- module A                 module B                  module C
-- import B                 import C
--
-- a = ...                  b = ...                   c = ...
-- b = B.b                  c = C.c                   a = ...
--                          a = C.a

data CompiledModule a = CompiledModule
  { cModuleName    :: ModuleName
  , cModuleImports :: [Import]
  , cModuleExports :: [Name]
  , cModuleEnv     :: a
  , cModuleDeps    :: [CompiledModule a]
  }
  deriving Show


compileToChez :: TypedModuleGroup -> CompiledModule Chez.Env
compileToChez (TypedModuleGroup m deps) = CompiledModule
  { cModuleName    = moduleName m
  , cModuleImports = moduleImports m
  , cModuleExports = moduleExports m
  , cModuleEnv     = Chez.builtins <> env
  , cModuleDeps    = []
  }
  where env = foldl Chez.compileModule mempty (deps ++ [m])
