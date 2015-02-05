{-# LANGUAGE ViewPatterns, TupleSections, RecordWildCards, ScopedTypeVariables, DeriveDataTypeable #-}

module Output.Tags(Tags, writeTags, readTags, listTags, filterTags, searchTags) where

import Data.List.Extra
import Data.Tuple.Extra
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.Vector.Storable as V
import qualified Data.ByteString.Char8 as BS
import Data.Word

import Input.Type
import Query
import General.Util
import General.Store

-- matches (a,b) if i >= a && i <= b

data Tags = Tags
    {packageNames :: BS.ByteString -- sorted
    ,categoryNames :: BS.ByteString -- sorted
    ,packageIds :: V.Vector (Id, Id)
    ,categoryOffsets :: V.Vector Word32 -- position I start, use +1 to find one after I end
    ,categoryIds :: V.Vector (Id, Id)
    ,moduleNames :: BS.ByteString -- not sorted
    ,moduleIds :: V.Vector (Id, Id)
    } deriving Typeable

join0 :: [String] -> BS.ByteString
join0 = BS.pack . intercalate "\0"

split0 :: BS.ByteString -> [BS.ByteString]
split0 = BS.split '\0'

writeTags :: StoreWrite -> (String -> [(String,String)]) -> [(Maybe Id, Item)] -> IO ()
writeTags store extra xs = storeWriteType store (undefined :: Tags) $ do
    let splitPkg = splitIPackage xs
    let packages = sortOn (lower . fst) $ addRange splitPkg
    let categories = map (first snd) $ Map.toList $ Map.fromListWith (++)
            [((weightTag ex, joinPair ":" ex),[rng]) | (p,rng) <- packages, ex <- extra p]

    storeWriteBS store $ join0 $ map fst packages
    storeWriteBS store $ join0 $ map fst categories
    storeWriteV store $ V.fromList $ map snd packages
    storeWriteV store $ V.fromList $ scanl (+) (0 :: Word32) $ map (genericLength . snd) categories
    storeWriteV store $ V.fromList $ concatMap snd categories

    let modules = addRange $ concatMap (splitIModule . snd) splitPkg
    storeWriteBS store $ join0 $ map fst modules
    storeWriteV store $ V.fromList $ map snd modules
    where
        addRange :: [(String, [(Maybe Id,a)])] -> [(String, (Id, Id))]
        addRange xs = [(a, (minimum is, maximum is)) | (a,b) <- xs, let is = mapMaybe fst b, a /= "", is /= []]

        weightTag ("set",x) = fromMaybe 0.9 $ lookup x [("stackage",0.0),("haskell-platform",0.1)]
        weightTag ("package",x) = 1
        weightTag ("category",x) = 2
        weightTag ("license",x) = 3
        weightTag _ = 4


readTags :: StoreRead -> Tags
readTags store = Tags (storeReadBS x1) (storeReadBS x2) (storeReadV x3) (storeReadV x4) (storeReadV x5) (storeReadBS x6) (storeReadV x7)
    where [x1,x2,x3,x4,x5,x6,x7] = storeReadList $ storeReadType (undefined :: Tags) store


listTags :: Tags -> [String]
listTags Tags{..} = let (a,b) = span ("set:" `isPrefixOf`) (f categoryNames) in a ++ map ("package:"++) (f packageNames) ++ b
    where f = map BS.unpack . split0

lookupTag :: Tags -> (String, String) -> [(Id,Id)]
lookupTag Tags{..} ("package",x) = map (packageIds V.!) $ findIndices (== BS.pack x) $ split0 packageNames
lookupTag Tags{..} ("module",x) = map (moduleIds V.!) $ findIndices (== BS.pack x) $ split0 moduleNames
lookupTag Tags{..} x = concat
    [ V.toList $ V.take (fromIntegral $ end - start) $ V.drop (fromIntegral start) categoryIds
    | i <- findIndices (== BS.pack (joinPair ":" x)) $ split0 categoryNames
    , let start = categoryOffsets V.! i, let end = categoryOffsets V.! (i + 1)
    ]

filterTags :: Tags -> [Scope] -> (Id -> Bool)
filterTags ts qs = let fs = map (filterTags2 ts . snd) $ groupSort $ map (scopeCategory &&& id) qs in \i -> all ($ i) fs

filterTags2 ts qs = \i -> let g (lb,ub) = i >= lb && i <= ub in not (any g neg) && (null pos || any g pos)
    where (pos, neg) = both (map snd) $ partition fst $ concatMap f qs
          f (Scope sense cat val) = map (sense,) $ lookupTag ts (cat,val)

searchTags :: Tags -> [Scope] -> [(Score,Id)]
searchTags ts qs = map ((0,) . fst) $ concat [lookupTag ts (cat,val) | Scope True cat val <- qs]
