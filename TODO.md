# TODO

## In-game testen (v1.1.0-beta2)

- [ ] **Want-ster in de Adventure Guide verschijnt.** De lootlijst wordt via `EncounterJournal.encounter.info.LootContainer.ScrollBox` + `ScrollUtil.AddInitializedFrameCallback` versierd; dat is alleen tegen een mock getest. Geen sterren? `/resetradar debug` aanzetten en de melding noteren.
- [ ] **Dubbele vinkjes?** De vinkjes rechts in de lootlijst zijn waarschijnlijk van Blizzard zelf (Midnight). Als ResetRadar's vinkje op het icoon dubbel is: eigen vinkje weghalen, alleen de ster houden.
- [ ] **Journal-scan klopt:** voor een bekende raid het aantal missende appearances vergelijken met wat je verwacht. Onzeker: of `C_EncounterJournal.GetLootInfoByIndex` zonder geselecteerde boss alle loot van de instance geeft met een link voor de gekozen moeilijkheid.
- [ ] **Balk onder de Adventure Guide** toont per moeilijkheid `missend/totaal` en de geselecteerde boss.
- [ ] **Want-regels in de checklist** tonen per karakter *Chance/Locked* en verdwijnen/worden grijs na verzamelen.
- [ ] **Duitse client:** de starterlijst in Farm Targets gebruikt Engelse bossnamen en matcht niet. Na een journal-scan worden die vervangen door auto-targets met Duitse namen; controleren dat dat gebeurt.
- [ ] Interface-versie in de .toc nog actueel? (`/dump select(4, GetBuildInfo())`)
- [ ] Loot Manager: verkopen via `C_Container.UseContainerItem` vanuit een timer werkt nog in 12.x (eerst alleen dry-run testen).
- [ ] Concentration (`C_TradeSkillUI.GetChildProfessionInfo` / `GetConcentrationCurrencyID`) en de Great Vault World/Delves-rij werken in Midnight.
- [ ] **Pogingenteller:** een kill op de juiste boss + moeilijkheid telt één poging (niet twee keer per lockout). Controleren dat `ENCOUNTER_END` de bossnaam geeft zoals in de journal (anders telt hij niet).
- [ ] **Drop-melding:** `ENCOUNTER_LOOT_RECEIVED` / `CHAT_MSG_LOOT` in Midnight-instances (kunnen secret zijn; dan blijft de melding weg).
- [ ] **Gesammelt-melding:** alleen na `NEW_MOUNT_ADDED` / `TRANSMOG_COLLECTION_SOURCE_ADDED` e.d., nooit bij inloggen.
- [ ] **Tier-sets:** `C_TransmogSets.GetAllSets` levert class-sets met `description` = moeilijkheid (Raid Finder/Normal/Heroic/Mythic) en `patchID`; het juiste tier wordt gekozen en PvP-sets vallen weg.
- [ ] **Planner:** aantallen kloppen met de Transmog-tab; "Alleen eigen armortype" klopt voor jouw klassen.
- [ ] **Duitse client:** teksten passen in knoppen/kolommen (sommige zijn langer).
- [ ] Als alles werkt: `v1.1.0` als gewone release taggen.

## Ideeën

- [x] **Pogingenteller per mount** (zoals Rarity): "Invincible: 37 kills", automatisch geteld bij elke kill op de juiste moeilijkheid.
- [x] **Melding bij een gewild item:** geluid/balk als een Want-item dropt of verzameld wordt.
- [x] **Weekplanner:** "deze week nog te doen" per alt, gesorteerd op welke raid de meeste missende items oplevert voor de bosses die nog open staan.
- [x] **Tier-sets per class:** hoeveel stukken van de huidige tier je per alt nog mist en uit welke moeilijkheid.
- [x] **Want vanuit de Transmog-tab:** rechtsklik op een boss of raid ("alles van deze boss willen").
- [x] **Duitse vertaling** van de interface (`Locales.lua`, `GetLocale() == "deDE"`).
