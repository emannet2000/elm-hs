{-# LANGUAGE OverloadedStrings #-}

-- | Demo data mirroring the original localStorage seeds of the CRM.
-- Only runs when the users table is empty (and SEED_DEMO is enabled).
module ECC.Seed (seedIfEmpty) where

import Control.Monad (forM_, forM, void)
import qualified Data.Text as T
import Data.Text (Text)
import Data.Time.Calendar (Day, addDays)
import Data.Time.Clock (getCurrentTime, utctDay)
import Database.PostgreSQL.Simple

import ECC.Auth (hashPassword)

seedIfEmpty :: Connection -> Bool -> IO ()
seedIfEmpty conn enabled =
  if not enabled
    then putStrLn "[seed] SEED_DEMO disabled"
    else do
      (Only n:_) <- query_ conn "SELECT COUNT(*) FROM users" :: IO [Only Int]
      case n of
        0 -> seed conn
        _ -> pure ()

seed :: Connection -> IO ()
seed conn = do
  putStrLn "[seed] seeding demo data…"
  today <- utctDay <$> getCurrentTime
  let d :: Int -> Day
      d n = addDays (fromIntegral n) today
      rel n = d (-n)   -- days ago
      ahead n = d n    -- days from now

  hash <- hashPassword "password123"
  let users =
        [ ("admin@ecc.com" :: Text, "System Admin" :: Text, "admin" :: Text)
        , ("aya@ecc.com",   "Aya Reyes",   "consultant")
        , ("marco@ecc.com", "Marco Lim",   "consultant")
        , ("hana@ecc.com",  "Hana Youssef","consultant")
        , ("devon@ecc.com", "Devon Cruz",  "viewer")
        ]
  forM_ users $ \(email, name, role) ->
    void $ execute conn
      "INSERT INTO users (email, password_hash, name, role) VALUES (?,?,?,?)"
      (email, hash, name, role)

  (Only year:_) <- query_ conn "SELECT date_part('year', CURRENT_DATE)::int" :: IO [Only Int]

  -- (name, email, phone, source, consultantId, quality, stage, dest, service,
  --  notes, lastContact, followup)
  let leads =
        [ ("Maria Santos"::Text,"maria.santos@gmail.com"::Text,"+63 917 555 0142"::Text,"Website"::Text,2::Int,"Hot"::Text,"Qualified"::Text,
           "Canada"::Text,"Student Visa"::Text,"Has IELTS 7.0, wants Fall intake."::Text, rel 12, rel (-8))
        , ("Ahmed Al-Farsi","a.farsi@outlook.com","+971 50 555 2210","Referring Agent",3,"Warm","Consultation Booked",
           "Australia","Work Visa","Employer sponsorship pending.", rel 9, rel (-6))
        , ("Grace Villanueva","grace.v@yahoo.com","+63 918 555 0099","School Partner",4,"Hot","Proposal Sent",
           "New Zealand","Student Visa","Nursing pathway, needs NZQA assessment.", rel 7, rel (-3))
        , ("Youssef Nabil","y.nabil@gmail.com","+971 55 555 3321","WhatsApp",5,"Cold","New Lead",
           "UK","Immigration Consultation","Initial inquiry only, needs qualification call.", rel 15, ahead 5)
        , ("Liza Fernandez","liza.fernandez@gmail.com","+63 920 555 0187","Facebook",2,"Warm","Contacted",
           "Canada","Work Visa","Caregiver pathway, gathering documents.", rel 10, ahead 2)
        , ("Karim Haddad","karim.h@hotmail.com","+971 56 555 4410","Referral",3,"Hot","Initial Assessment",
           "Canada","Student Visa","Sibling already an ECC client.", rel 6, ahead 1)
        ]
      pad4 x = let s = show x in replicate (4 - length s) '0' ++ s
  leadIds <- fmap (concatMap head) $ forM (zip ([41 ..] :: [Int]) leads) $
    \(i, (nm, em, ph, src, cid, q, st, dst, sv, notes, lc, fu)) ->
      returning conn
        "INSERT INTO leads (lead_number, full_name, email, phone, source, consultant_id, quality, stage, destination, service, notes, last_contact, next_followup) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) RETURNING id"
        [ ( T.pack ("L-" ++ show (year :: Int) ++ "-" ++ pad4 i)
          , nm, Just em, Just ph, Just src, Just (cid :: Int), Just q, st
          , Just dst, Just sv, Just notes, Just lc, Just fu ) ] :: IO [[Int]]

  let clients =
        [ (T.pack ("ECC-" ++ show (year :: Int) ++ "-00087"), "Rosa Dimaculangan" :: Text, "rosa.d@gmail.com" :: Text, "+971 52 555 1187" :: Text, 4 :: Int)
        , (T.pack ("ECC-" ++ show (year :: Int) ++ "-00088"), "Fahad Al-Otaibi", "fahad.o@gmail.com", "+971 50 555 9902", 3)
        ]
  forM_ clients $ \(num, nm, em, ph, officer) ->
    void $ execute conn
      "INSERT INTO clients (client_number, full_name, email, phone, case_officer_id) VALUES (?,?,?,?,?)"
      (num, nm, Just em, Just ph, Just (officer :: Int))

  void $ execute conn
    "INSERT INTO cases (client_id, service_category, destination, stage, next_deadline) VALUES ((SELECT id FROM clients WHERE client_number=?),'Student Visa','Canada','Documents Under Review',?)"
    (T.pack ("ECC-" ++ show (year :: Int) ++ "-00087"), rel 5)
  void $ execute conn
    "INSERT INTO cases (client_id, service_category, destination, stage, next_deadline) VALUES ((SELECT id FROM clients WHERE client_number=?),'Work Visa','Australia','Decision Pending',?)"
    (T.pack ("ECC-" ++ show (year :: Int) ++ "-00088"), ahead 9)

  let tasks =
        [ (leadIds !! 0, "Call Maria about IELTS results" :: Text, rel 2, "High" :: Text, "Pending" :: Text)
        , (leadIds !! 2, "Send NZQA checklist to Grace", rel 1, "Medium", "In Progress")
        , (leadIds !! 4, "Collect caregiver documents from Liza", ahead 2, "High", "Pending")
        , (leadIds !! 1, "Confirm consultation slot with Ahmed", ahead 3, "Low", "Pending")
        , (leadIds !! 5, "Verify Karim's passport copy", ahead 5, "Medium", "Pending")
        , (leadIds !! 3, "Qualification call with Youssef", ahead 7, "Low", "Done")
        ]
  forM_ tasks $ \(lid, title, due, prio, status) ->
    void $ execute conn
      "INSERT INTO tasks (lead_id, title, due_date, priority, status) VALUES (?,?,?,?,?)"
      (lid :: Int, title, Just due, prio, status)

  let acts =
        [ (leadIds !! 0, "note" :: Text, "Added note: Has IELTS 7.0, wants Fall intake." :: Text, rel 12)
        , (leadIds !! 0, "stage_change", "Moved to Qualified", rel 9)
        , (leadIds !! 2, "call", "Discovery call completed", rel 7)
        , (leadIds !! 1, "stage_change", "Moved to Consultation Booked", rel 5)
        ]
  forM_ acts $ \(lid, kind, desc, day) ->
    void $ execute conn
      "INSERT INTO activities (lead_id, type, description, date) VALUES (?,?,?,?)"
      (lid, kind, desc, day)

  putStrLn "[seed] demo data seeded"
