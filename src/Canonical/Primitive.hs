module Canonical.Primitive where

import           ELC.Primitive                  ( modPrim )
import           Syn                           as Syn

primitives :: [(Syn.Name, Syn.ModuleName)]
primitives = map (, modPrim) $ miscFunctions <> numFunctions <> list <> types

miscFunctions :: [Syn.Name]
miscFunctions = ["error"]

numFunctions, list, types :: [Syn.Name]
numFunctions = ["+", "*", "-"]
list = ["::", "[]"]
types = ["Int", "String"]
