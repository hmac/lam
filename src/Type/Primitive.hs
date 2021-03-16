module Type.Primitive where

import           AST                            ( ConMeta(..) )
import           Data.Name                      ( Name )

primitiveCtorInfo :: [(Name, ConMeta)]
primitiveCtorInfo =
  [ ("Kite.Primitive.[]"  , listNilMeta)
  , ("Kite.Primitive.::"  , listConsMeta)
  , ("Kite.Primitive.MkIO", mkIO)
  ]

listNilMeta :: ConMeta
listNilMeta = ConMeta { conMetaTag      = 0
                      , conMetaArity    = 0
                      , conMetaTypeName = "Kite.Primitive.List"
                      }

listConsMeta :: ConMeta
listConsMeta = ConMeta { conMetaTag      = 1
                       , conMetaArity    = 2
                       , conMetaTypeName = "Kite.Primitive.List"
                       }

mkIO :: ConMeta
mkIO = ConMeta { conMetaTag      = 0
               , conMetaArity    = 1
               , conMetaTypeName = "Kite.Primitive.IO"
               }