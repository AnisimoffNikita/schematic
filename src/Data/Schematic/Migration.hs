{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TemplateHaskell #-}

module Data.Schematic.Migration where

import Data.Kind
import Data.Schematic.Path
import Data.Schematic.Schema
import Data.Schematic.Utils
import Data.Singletons.Prelude hiding (All)
import Data.Singletons.TypeLits
import Data.Vinyl hiding (Dict)


data Path
  = PKey Symbol -- traverse into the object by key
  | PTraverse   -- traverse into the array

data instance Sing (p :: Path) where
  SPKey :: KnownSymbol s => Sing s -> Sing ('PKey s)
  SPTraverse :: Sing 'PTraverse

instance KnownSymbol s => SingI ('PKey s) where
  sing = SPKey sing

instance SingI 'PTraverse where
  sing = SPTraverse

-- Result type blueprint
data Builder
  = BKey Schema Symbol Builder  -- field schema
  | BTraverse Schema Builder  -- array schema
  | BScalar Schema

-- Working with keys

type family SchemaByKey (fs :: [(Symbol, Schema)]) (s :: Symbol) :: Schema where
  SchemaByKey ( '(fn,s) ': tl) fn = s
  SchemaByKey ( '(a, s) ': tl) fn = SchemaByKey tl fn

type family DeleteKey (acc :: [(Symbol, Schema)]) (fn :: Symbol) (fs :: [(Symbol, Schema)]) :: [(Symbol, Schema)] where
  DeleteKey acc fn ('(fn, a) ': tl) = acc :++ tl
  DeleteKey acc fn (fna ': tl) = acc :++ (fna ': tl)

type family UpdateKey (acc :: [(Symbol, Schema)]) (fn :: Symbol) (fs :: [(Symbol, Schema)]) (s :: Schema) :: [(Symbol, Schema)] where
  UpdateKey acc fn ( '(fn, n) ': tl ) s = '(fn, s) ': tl
  UpdateKey acc fn ( '(a, n) ': tl) s = UpdateKey (acc :++ '[ '(a,n) ]) fn tl s

-- schema updates

type family Build (b :: Builder) :: Schema where
  Build ('BKey ('SchemaObject fs) fn z) = 'SchemaObject (UpdateKey '[] fn fs (Build z))
  Build ('BTraverse ('SchemaArray acs s) z) = 'SchemaArray acs (Build z)
  Build ('BScalar s) = s

type family MakeBuilder (s :: Schema) (d :: Diff) :: Builder where
  MakeBuilder s ('Diff '[] a) = 'BScalar (ApplyAction a s)
  MakeBuilder ('SchemaObject fs) ('Diff ('PKey fn ': tl) a) =
    'BKey ('SchemaObject fs) fn (MakeBuilder (SchemaByKey fs fn) ('Diff tl a))
  MakeBuilder ('SchemaArray acs s) ('Diff ('PTraverse ': tl) a) =
    'BTraverse ('SchemaArray acs s) (MakeBuilder s ('Diff tl a))

type family ApplyAction (a :: Action) (s :: Schema) :: Schema where
  ApplyAction ('AddKey fn s) ('SchemaObject fs) = 'SchemaObject ('(fn,s) ': fs)
  ApplyAction ('DeleteKey fn) ('SchemaObject fs) = 'SchemaObject (DeleteKey '[] fn fs)
  ApplyAction ('Update s) t = s

type family ApplyMigration (m :: Migration) (s :: Schema) :: (Revision, Schema) where
  ApplyMigration ('Migration r '[])       s = '(r, s)
  ApplyMigration ('Migration r (d ': ds)) s =
    '(r, Snd (ApplyMigration ('Migration r ds) (Build (MakeBuilder s d))))

-- working with revisions

type family SchemaByRevision (r :: Revision) (vd :: Versioned) :: Schema where
  SchemaByRevision r ('Versioned s (('Migration r ds) ': ms)) =
    Snd (ApplyMigration ('Migration r ds) s)
  SchemaByRevision r ('Versioned s (m ': ms)) =
    SchemaByRevision r ('Versioned (Snd (ApplyMigration m s)) ms)

-- type family Reverse (acc :: [(Revision, Schema)]) (rs :: [(Revision, Schema)]) :: [(Revision, Schema)] where
--   Reverse acc '[] = acc
--   Reverse acc (h ': tl) = Reverse (h ': acc) tl

type family Migratable (rs :: [(Revision, Schema)]) :: Constraint where
  -- constraint duplication
  Migratable ('(r,s) ': '(r', s') ': tl) =
    (SingI s, MigrateSchema s s', TopLevel s, Migratable ('(r',s') ': tl))
  Migratable ('(r,s) ': '[])             = (TopLevel s, SingI s)
  -- Migratable '[]                         = ('True ~ 'False)

-- data NonEmpty a = a :| [a]

-- data instance Sing (ne :: NonEmpty a) where
--   SNECons :: Known (Sing e), Known (Sing l))=> Sing (e :: k) -> Sing (l :: [k]) -> Sing (e ':| l)

data Revisions = Revisions
  Schema -- top version
  [(Revision, Schema)]

data instance Sing (rs :: Revisions) where
  SRevisions
    :: (SingI schema, SingI rps, Known (Dict (ElemOf schema prs)))
    => Sing schema
    -> Sing rps
    -> Sing ('Revisions schema rps)

-- -- | Heterogenous list with a proof of element schema included in the list itself.
-- data ElemList :: k -> [k] -> Type where
--   Singl :: Known (Sing schema) => Sing schema -> ElemList schema '[schema]
--   KeepProof :: Known (Sing new) => Sing new -> ElemList schema ss -> ElemList schema (new ': ss)
--   NewProof :: Known (Sing new) => Sing new -> ElemList schema ss -> ElemList new (new ': ss)

type family ElemOf (e :: k) (l :: [(a,k)]) :: Constraint where
  ElemOf e '[] = 'True ~ 'False
  ElemOf e ( '(a, e) ': es) = ()
  ElemOf e (n ': es) = ElemOf e es

-- | Extracts revision/schema pairs from @Versioned@ in reverse order.
type family AllVersions (vd :: Versioned) :: Revisions where
  AllVersions ('Versioned s ms) = AllVersions' ('Revisions s '[ '("initial", s) ]) ms

type family AllVersions' (acc :: Revisions) (ms :: [Migration]) :: Revisions where
  AllVersions' acc '[] = acc
  AllVersions' ('Revisions tv rs) (m ': ms) =
    AllVersions' ('Revisions (Snd (ApplyMigration m tv)) (rs :++ '[(ApplyMigration m tv)])) ms

type family TopVersion (rs :: Revisions) :: Schema where
  TopVersion ('Revisions s rs) = s

type family SchemaPairs (rs :: Revisions) :: [(Revision, Schema)] where
  SchemaPairs ('Revisions s rs) = rs

class MigrateSchema (a :: Schema) (b :: Schema) where
  migrate :: JsonRepr a -> JsonRepr b

instance MigrateSchema a a where
  migrate = id

data Action = AddKey Symbol Schema | Update Schema | DeleteKey Symbol

data instance Sing (a :: Action) where
  SAddKey
    :: (SingI n, SingI s)
    => Sing n
    -> Sing s
    -> Sing ('AddKey n s)
  SUpdate :: (SingI s) => Sing s -> Sing ('Update s)
  SDeleteKey :: KnownSymbol s => Sing s -> Sing ('DeleteKey s)

-- | User-supplied atomic difference between schemas.
-- Migrations can consists of many differences.
data Diff = Diff [Path] Action

data instance Sing (diff :: Diff) where
  SDiff
    :: (SingI jp, SingI a)
    => Sing (jp :: [Path])
    -> Sing (a :: Action)
    -> Sing ('Diff jp a)

-- | User-provided name of the revision.
type Revision = Symbol

data Migration = Migration Revision [Diff]

data instance Sing (m :: Migration) where
  SMigration
    :: (KnownSymbol r, SingI ds)
    => Sing r
    -> Sing ds
    -> Sing ('Migration r ds)

data Versioned = Versioned Schema [Migration]

data instance Sing (v :: Versioned) where
  SVersioned
    :: (SingI s, SingI ms)
    => Sing (s :: Schema)  -- base version
    -> Sing (ms :: [Migration]) -- a bunch of migrations
    -> Sing ('Versioned s ms)

type SchemaExample
  = 'SchemaObject
    '[ '("foo", 'SchemaArray '[ 'AEq 1] ( 'SchemaNumber '[ 'NGt 10 ]))
     , '("bar", 'SchemaOptional ( 'SchemaText '[ 'TRegex "\\w+", 'TEnum '["foo", "bar"]]))]

type VS =
  'Versioned SchemaExample
    '[ 'Migration "test_revision"
       '[ 'Diff '[ 'PKey "foo" ] ('Update ('SchemaText '[])) ] ]

jsonExample :: JsonRepr (TopVersion (AllVersions VS))
jsonExample = ReprObject $
  FieldRepr (ReprText "foo")
    :& FieldRepr (ReprOptional (Just (ReprText "bar")))
    :& RNil