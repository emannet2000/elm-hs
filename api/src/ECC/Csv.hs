{-# LANGUAGE OverloadedStrings #-}

module ECC.Csv
  ( leadsCsv
  , clientsCsv
  , parseCsv
  ) where

import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Time (Day, UTCTime)

import ECC.Models

leadsCsv :: [Lead] -> BL.ByteString
leadsCsv leads = renderCsv $
  [ [ "Lead Number", "Full Name", "Email", "Phone", "Source", "Consultant"
    , "Quality", "Stage", "Destination", "Service", "Last Contact"
    , "Next Follow-up", "Notes", "Created At"
    ]
  ]
  <> map leadRow leads

leadRow :: Lead -> [Text]
leadRow l =
  [ cell (leadNumber l)
  , cell (fullName l)
  , opt (email l)
  , opt (phone l)
  , opt (source l)
  , opt (consultantName l)
  , opt (quality l)
  , cell (stage l)
  , opt (destination l)
  , opt (service l)
  , day (lastContact l)
  , day (nextFollowup l)
  , opt (notes l)
  , utcCell (createdAt l)
  ]

clientsCsv :: [Client] -> BL.ByteString
clientsCsv clients = renderCsv $
  [ [ "Client Number", "Full Name", "Email", "Phone", "Case Officer", "Created At" ]
  ]
  <> map clientRow clients

clientRow :: Client -> [Text]
clientRow c =
  [ cell (clientNumber c)
  , cell (clientFullName c)
  , opt (clientEmail c)
  , opt (clientPhone c)
  , opt (caseOfficerName c)
  , utcCell (clientCreatedAt c)
  ]

renderCsv :: [[Text]] -> BL.ByteString
renderCsv rows =
  BL.fromStrict
    (TE.encodeUtf8 ("\xFEFF" <> T.intercalate "\r\n" (map line rows)))
  where
    line r = T.intercalate "," r

cell :: Text -> Text
cell = csvCell . T.stripEnd

opt :: Maybe Text -> Text
opt = maybe "" (csvCell . T.stripEnd)

day :: Maybe Day -> Text
day = maybe "" (\d -> T.pack (formatTime defaultTimeLocale "%Y-%m-%d" d))

utcCell :: UTCTime -> Text
utcCell t =
  T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M" t)

csvCell :: Text -> Text
csvCell v =
  let guarded = case T.uncons v of
        Just (c, _) | c `elem` ("=+-@" :: String) -> T.cons '\'' v
        _ -> v
  in if needsQuoting guarded
       then "\"" <> T.replace "\"" "\"\"" guarded <> "\""
       else guarded

needsQuoting :: Text -> Bool
needsQuoting t =
  T.any (\c -> c == ',' || c == '"' || c == '\n' || c == '\r') t

-- ---------- parsing ----------

-- | RFC 4180 reader: quoted fields (with doubled-quote escapes), commas and
-- newlines inside quotes, CR, LF or CRLF row terminators.  Rows whose cells
-- are all blank are dropped; a leading UTF-8 BOM is ignored.
parseCsv :: Text -> [[Text]]
parseCsv raw =
  let t = maybe raw id (T.stripPrefix "\xFEFF" raw)
  in filter (\r -> any (not . T.null . T.strip) r)
       (map (map T.pack) (rowsOf (T.unpack t)))

rowsOf :: String -> [[String]]
rowsOf [] = []
rowsOf s = row : rowsOf rest
  where
    (row, rest) = rowOf s

rowOf :: String -> ([String], String)
rowOf s =
  let (f, r) = fieldOf s
      gather acc cs = case cs of
        (',':cs') -> let (f', r') = fieldOf cs' in gather (f' : acc) r'
        _         -> (f : reverse acc, skipEol cs)
  in gather [] r

skipEol :: String -> String
skipEol ('\r':'\n':cs) = cs
skipEol ('\n':cs)      = cs
skipEol ('\r':cs)      = cs
skipEol cs             = cs

fieldOf :: String -> (String, String)
fieldOf ('"':s) = quoted "" s
fieldOf s       = plain "" s

plain :: String -> String -> (String, String)
plain acc s@(c:_)
  | c == ',' || c == '\n' || c == '\r' = (reverse acc, s)
plain acc (c:cs) = plain (c : acc) cs
plain acc []     = (reverse acc, [])

quoted :: String -> String -> (String, String)
quoted acc ('"':'"':cs) = quoted ('"' : acc) cs
quoted acc ('"':cs)     = (reverse acc, cs)
quoted acc (c:cs)       = quoted (c : acc) cs
quoted acc []           = (reverse acc, [])
