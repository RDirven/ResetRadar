# ResetRadar

Lichtgewicht WoW Retail-addon (Midnight, Interface 120105/120100): een dagelijkse/wekelijkse checklist over al je karakters, plus twee modules: **Farm Targets** (standaard aan) en **Loot Manager** (standaard **uit**).

## Installatie

1. Kopieer de map `ResetRadar` naar `World of Warcraft\_retail_\Interface\AddOns\`.
2. Start WoW (of `/reload`) en zet de addon aan in de AddOns-lijst.
3. Log op elk karakter één keer in, dan verschijnt het in het overzicht. Open op elk karakter één keer het professions-venster als je concentration wilt zien.

Opgeslagen data staat in `WTF\Account\<account>\SavedVariables\ResetRadar.lua` (`ResetRadarDB`, per karakter onder `Naam-Realm`).

## Slash commands

| Command | Doet |
|---|---|
| `/resetradar` (of `/rradar`) | Venster openen/sluiten |
| `/resetradar config` | Instellingen (Esc → Options → AddOns → ResetRadar) |
| `/resetradar farm` | Direct naar het Farm Targets-paneel |
| `/resetradar loot` | Loot Manager (alleen als de module aan staat) |
| `/resetradar reset <Naam>` of `<Naam-Realm>` | Data van een karakter wissen |
| `/resetradar scan` | Lockouts opnieuw opvragen en scannen |
| `/resetradar debug` | Debugmeldingen aan/uit (overgeslagen API's, ontbrekende events, module-fouten) |

## Bediening

- **Rijen** zijn taken, **kolommen** karakters (current character eerst). Bij veel alts verschijnen `<` `>`-knoppen om door kolommen te bladeren. Scrollen met het muiswiel.
- Statussen: ✔-icoon + groen = klaar, ?-icoon (wachten) + geel = bezig, ✖-icoon + rood = open, grijs `-` = niet van toepassing. De iconen verschillen in vorm, dus ook zonder kleur leesbaar. Een `*` achter de tekst betekent: inmiddels gereset sinds dat karakter laatst gezien is.
- **Rechtsklik op een rijlabel**: rij verbergen voor alle karakters. **Rechtsklik op een cel**: alleen voor dat karakter verbergen. **Rechtsklik op een karakternaam**: karakter verbergen, resetten of verwijderen. "Show hidden" toont alles weer, zodat je het terug kunt zetten.
- "View: all characters / this character" wisselt tussen alle karakters en alleen het huidige.
- Handmatige items: typ een naam rechtsboven, kies Weekly/Daily en Character/Account, klik Add. Klik op een cel om af te vinken.
- Venster: slepen om te verplaatsen, rechtsonder om te vergroten, Esc sluit, schaal via de instellingen. Positie en grootte worden onthouden.

## Een checklist-item toevoegen (code)

Alle items staan in `Checklist.lua`. Een nieuw item is één blok:

```lua
RR:RegisterItem({
  key = "myWeekly", label = "My weekly thing", resetType = "weekly", order = 45,
  check = function(ctx)
    local done = C_QuestLog.IsQuestFlaggedCompleted(12345)
    return { state = done and "done" or "open" }
  end,
})
```

- `check` draait in een `pcall` en alleen voor het ingelogde karakter. Return `nil` = vorige waarde houden, `false` = item weghalen voor dit karakter.
- Groepen (zoals raids) returnen `{ sub = { key = { label, state, cur, max, text, tip } } }`.
- Een quest vastpinnen kan zonder code: zet `{ questID = 12345, label = "...", resetType = "weekly" }` in `RR.Data.pinnedQuests` bovenin `Checklist.lua`. Extra currencies gaan in `RR.Data.extraCurrencies`.
- Zet de labeltekst in `Locales.lua`.

## Een Farm Target toevoegen

**In het spel:** tab *Farm Targets* → *Add target...*
- Item: item-ID, shift-klik een item in het veld, of een itemnaam (dat laatste werkt alleen als het item al in de client-cache staat).
- Bron: *Pick from journal...* vult instance, map-ID en boss in vanuit de Encounter Journal. Je kunt alles ook met de hand invullen (bijvoorbeeld als de journal een boss niet goed koppelt).
- Difficulty IDs: kommagescheiden (14 Normal, 15 Heroic, 16 Mythic, 17 LFR, 1/2/23 dungeon Normal/Heroic/Mythic, 3–6 legacy 10/25 N/H). *List...* toont de namen.
- Of vul een **Quest ID** in voor een dagelijkse/wekelijkse questbron.
- "One lockout for all listed difficulties": vink aan als één kill alle genoemde moeilijkheden opsoupeert.
- Min lvl: karakters onder dit level krijgen "No" (niet geschikt).

**In code:** voeg een regel toe aan `STARTER` in `Modules/FarmTargets.lua` (wordt alleen bij de eerste keer geladen):

```lua
{ itemID = 50818, sources = { { type = "lockout", mapID = 631, instance = "Icecrown Citadel",
  encounter = "The Lich King", difficulties = { 6 }, resetType = "weekly" } } },
```

Statussen per karakter: **Chance** (nog een kill/loot-roll beschikbaar), **Locked** (deze reset al gedood), **No** (niet geschikt), **?** (karakter nog niet gescand). Er worden nooit dropkansen getoond. Mounts, pets, toys en transmog worden account-breed als "collected" herkend en grijs getoond of verborgen (instelbaar). Het tabblad *Mounts* sorteert gevolgde mounts op het aantal karakters dat nog een kans heeft.

## Collections: ontbrekende mounts en transmog per raid

Module **Collections** (standaard aan), tabblad **Transmog**:

- Klik één keer op **Scan journal** (en opnieuw na een patch; het tabblad waarschuwt als de data van een oudere game-versie is). De scan loopt alle raids en dungeons van alle expansies langs, per moeilijkheid. Hij duurt ongeveer een minuut, pauzeert in combat en draait niet als de Adventure Guide open is. Het lootfilter van de journal wordt daarna teruggezet.
- Per raid en moeilijkheid zie je **hoeveel appearances je nog mist** (bijv. `14/120`), met een uitsplitsing per armortype in de tooltip. Klik op een rij om per boss te zien wat er mist (tooltip met itemnamen).
- De karakterkolommen tonen per raid hoeveel bosses met ontbrekende loot dat karakter deze reset nog kan doen (`3/5`), en per boss *Chance/Locked*.
- Filters: raids, dungeons of alles, sorteren op expansie of op meeste missende items, complete raids verbergen. Optie "completionist" telt elk item-source in plaats van unieke appearances.
- **Ontbrekende mounts automatisch:** elke boss-drop mount uit de journal die je nog niet hebt, komt vanzelf in Farm Targets (gemarkeerd als *auto*), met de juiste boss en moeilijkheden. Rechtsklik verbergt er één. Een auto-target vervangt de starterregel voor hetzelfde item.

Beperkingen: alleen loot die de journal als bossdrop toont. Mounts van rare spawns, reputatie of achievements, en tier-stukken die uit tokens komen, worden niet gevonden. "Mist" geldt voor je hele account.

## Gebruikte API's en events

**Reset:** `C_DateAndTime.GetSecondsUntilDailyReset`, `C_DateAndTime.GetSecondsUntilWeeklyReset` (fallback `GetQuestResetTime`). De tijden komen van de client, dus EU/US gaat vanzelf goed. Elke opgeslagen waarde krijgt een `expires`-tijdstempel. Bij login, bij elke scan en bij het openen van het venster gaat alles wat verlopen is terug naar "open", voor álle karakters. Een alt die drie weken offline was, staat dus correct op open.

**Checklist:** `C_WeeklyRewards.GetActivities` / `HasAvailableRewards`, `C_MythicPlus.GetOwnedKeystoneChallengeMapID` / `GetOwnedKeystoneLevel` / `GetRunHistory` / `RequestMapInfo`, `C_ChallengeMode.GetMapUIInfo`, `RequestRaidInfo` + `GetNumSavedInstances` / `GetSavedInstanceInfo` / `GetSavedInstanceEncounterInfo`, `GetNumSavedWorldBosses` / `GetSavedWorldBossInfo`, `C_QuestLog.GetInfo` (frequency Daily/Weekly) / `IsQuestFlaggedCompleted` / `IsOnQuest`, `C_CurrencyInfo.GetCurrencyListInfo` / `GetCurrencyListLink` / `GetCurrencyIDFromLink` / `GetCurrencyInfo`, `GetProfessions` / `GetProfessionInfo`, `C_TradeSkillUI.GetChildProfessionInfo` / `GetConcentrationCurrencyID`, `C_MajorFactions.GetMajorFactionIDs` / `GetMajorFactionData`, `C_Calendar.OpenCalendar` / `GetNumDayEvents` / `GetDayEvent`.

**Collections:** `EJ_SelectInstance` / `EJ_SetDifficulty` / `EJ_IsValidInstanceDifficulty` / `EJ_SetLootFilter` / `EJ_GetLootFilter` / `EJ_GetNumLoot`, `C_EncounterJournal.GetLootInfoByIndex` / `SetSlotFilter`, `C_Item.GetItemInfoInstant`, `GetBuildInfo`. Niet in-game geverifieerd: dat `GetLootInfoByIndex` zonder geselecteerde boss alle loot van de instance geeft met een link voor de gekozen moeilijkheid.

**Farm Targets:** `C_MountJournal.GetMountFromItem` / `GetMountInfoByID`, `C_PetJournal.GetPetInfoByItemID` / `GetNumCollectedInfo`, `C_ToyBox.GetToyInfo`, `PlayerHasToy`, `C_TransmogCollection.GetItemInfo` / `GetAppearanceInfoBySource`, `EJ_GetNumTiers` / `EJ_GetTierInfo` / `EJ_SelectTier` / `EJ_GetInstanceByIndex` / `EJ_GetInstanceInfo` / `EJ_GetEncounterInfoByIndex`, `GetDifficultyInfo`.

**Loot Manager:** `C_Container.GetContainerNumSlots` / `GetContainerItemInfo` / `GetContainerItemEquipmentSetInfo` / `UseContainerItem`, `C_Item.GetItemInfo` / `GetCurrentItemLevel`, `ItemLocation:CreateFromBagAndSlot`, `C_TooltipInfo.GetBagItem` (binding en "Classes:" uit de tooltipregels), `C_EquipmentSet.GetEquipmentSetIDs` / `GetItemIDs`, `TooltipDataProcessor.AddTooltipPostCall`, `GetAverageItemLevel`.

**UI:** eigen frames (geen Blizzard-frames aangeraakt), `Settings.RegisterCanvasLayoutCategory` / `RegisterAddOnCategory` / `OpenToCategory`, `MenuUtil.CreateContextMenu` (met eigen fallback-menu), `StaticPopupDialogs`, `hooksecurefunc("ChatEdit_InsertLink")` voor shift-klik in invoervelden.

**Events:** `PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD`, `PLAYER_LOGOUT`, `PLAYER_REGEN_ENABLED`, `PLAYER_LEVEL_UP`, `QUEST_TURNED_IN`, `QUEST_LOG_UPDATE`, `UPDATE_INSTANCE_INFO`, `BOSS_KILL`, `ENCOUNTER_END`, `WEEKLY_REWARDS_UPDATE`, `CHALLENGE_MODE_COMPLETED`, `CHALLENGE_MODE_MAPS_UPDATE`, `CURRENCY_DISPLAY_UPDATE`, `TRADE_SKILL_LIST_UPDATE`, `MAJOR_FACTION_RENOWN_LEVEL_CHANGED`, `CALENDAR_UPDATE_EVENT_LIST`, `NEW_MOUNT_ADDED`, `NEW_PET_ADDED`, `NEW_TOY_ADDED`, `TRANSMOG_COLLECTION_UPDATED`, `GET_ITEM_INFO_RECEIVED`, `MERCHANT_SHOW`, `MERCHANT_CLOSED`, `BAG_UPDATE_DELAYED`. Elk event wordt in een `pcall` geregistreerd: bestaat een naam niet meer, dan wordt hij overgeslagen en meldt debugmodus dat.

**Robuustheid:** scans zijn gedebounced (1,5 s) en draaien nooit in combat. Een scan tijdens combat wordt uitgesteld tot `PLAYER_REGEN_ENABLED`. Er is geen `OnUpdate` voor data (alleen tijdens het slepen van de minimap-knop). Elke API-aanroep loopt via een nil-check plus `pcall` (`RR.Call`), elke checklist-check en elke module-methode draait in een `pcall`. Een module die 10 keer faalt, wordt voor die sessie uitgezet; de kern blijft werken. Midnight-"secret values" worden overgeslagen (`issecretvalue`).

## Niet automatisch te detecteren (dus handmatig of via een vastgepinde quest)

- **Specifieke wekelijkse quests van het seizoen, de weekly event-quest en de Timewalking-quest:** de addon herkent automatisch elke quest met frequency Daily/Weekly die je in je log hebt (gehad), maar heeft geen hardgecodeerde quest-ID's voor Midnight. Die kon ik niet betrouwbaar verifiëren. Actieve holidays (bijv. Timewalking) staan wel onderin het venster via de kalender. Wil je een vaste rij, pin dan de quest-ID in `RR.Data.pinnedQuests`.
- **Profession-cooldowns** (transmutes e.d.): alleen leesbaar als het professions-venster open is en per recept. Voeg ze toe als handmatig item.
- **Concentration** wordt alleen gelezen als het professions-venster open is en wordt met een tijdstempel getoond (geen schatting van regeneratie).
- **Delves:** de voortgang zit in de Great Vault-rij "World / Delves". Er is geen aparte delve-weekly-API gebruikt.
- **Currencies:** alleen currencies die zichtbaar zijn in je currency-lijst (ingeklapte headers worden niet opengeklapt, om je UI niet te wijzigen) plus `RR.Data.extraCurrencies`.
- **World bosses:** "klaar" zodra er deze week een world boss op slot staat. Welke boss deze week actief is, wordt niet bepaald.

## Niet in-game geverifieerd (graag testen)

Ik heb de addon niet in de client kunnen draaien. Hij is getest met een syntaxcheck (Lua 5.1) en een gesimuleerde WoW-API (login, lockouts, een alt die 3 weken offline was, een vers karakter zonder professions, combat-uitstel, een crashende module, de loot manager in dry-run, het negeren van items en het weigeren van verkoop bij een gesloten vendor). Specifiek nog te controleren:

- Interface `120100`: overgenomen van je eigen recente addon. Check met `/dump select(4, GetBuildInfo())` en pas de `.toc` aan als die afwijkt.
- `Enum.WeeklyRewardChestThresholdType.World` (fallback 6) voor de World/Delves-rij in Midnight.
- `C_TradeSkillUI.GetChildProfessionInfo` + `GetConcentrationCurrencyID` (TWW-API's) in Midnight.
- Starterlijst Farm Targets: map-ID's, Engelse bossnamen en difficulty-ID's (met name legacy 10/25 en of 10/25 een lockout delen). Matching gebeurt op de bossnaam uit `GetSavedInstanceEncounterInfo`, dus op een niet-Engelse client moet je de bossnamen aanpassen.
- Of `C_Container.UseContainerItem` vanuit een timer (zonder hardware-event) in 12.x nog verkoopt. De verkoopronde start vanaf je klik op *Sell*, de volgende items volgen met 0,25 s ertussen.
- Transmog: of een karakter een appearance alleen kan leren als het het armortype mag dragen. De "Mist nog op"-lijst gaat daarvan uit (class-restrictie uit de tooltip, anders armortype, mantels/shirts/tabards = alle classes). Voor wapens wordt de class-geschiktheid niet bepaald; dat staat ook in de tooltip.
- De tooltip-globals voor binding (`ITEM_ACCOUNTBOUND_UNTIL_EQUIP`, `ITEM_ACCOUNTBOUND`, enz.). Als Midnight die hernoemd heeft, wordt de binding "unknown" en blijft het item beschermd (het wordt niet verkocht) met de tekst "Could not verify how this item can be transferred".

## Loot Manager: wat hij precies doet

**Standaard UIT.** Aanzetten kan alleen via de instellingen en pas na een waarschuwingspopup die je moet bevestigen.

1. Alleen bij een vendor (`MERCHANT_SHOW`) bouwt hij een lijst. Hij scant alleen tassen 0–4, dus nooit equipped items.
2. **Dry-run is de standaard:** het tabblad toont "Dit zou verkocht worden" met de totale goudwaarde. Er wordt niets verkocht tot je op **Sell** klikt.
3. "Sell without confirmation" bestaat, staat uit en vraagt bij aanzetten een tweede waarschuwing. Ook dan worden high-value items nooit automatisch verkocht.
4. Regels (elk aan/uit): grijze junk (aan); soulbound gear met een al verzamelde appearance onder een item level-drempel (uit); warbound gear (aparte schakelaar, uit).
5. **Wordt nooit verkocht:** items op de ignore-lijst (via ID/shift-klik, of rechtsklik in de lijst), items in een equipment set, item-set/tier-stukken (oudere expansies alleen als je dat expliciet toestaat; de huidige expansie nooit), gear waarvan de appearance nog niet verzameld is of niet bepaald kan worden, quest items, items zonder verkoopprijs, en items in de cache die nog niet geladen zijn.
6. Items boven de high-value-drempel (standaard 100g) vragen een extra bevestiging.
7. Maximaal 12 items per ronde (instelbaar). De buyback-tab van de vendor houdt de laatste 12 vast, dus standaard is alles terug te kopen. Dat vangnet staat ook in de UI.
8. Verkopen gaat één voor één met 0,25 s ertussen. Vlak voor elk item controleert hij opnieuw of het nog hetzelfde item en dezelfde stack op die plek is en of de vendor nog open is. Hij stopt direct als de vendor sluit of combat begint.
9. Na afloop volgt een chatregel met wat er verkocht is en voor hoeveel (gemeten via je goudverschil).
10. **Warbound/tier-suggesties:** voor warbound, warbound-until-equipped en BoE-gear met een nog niet verzamelde appearance toont de tooltip (en de lijst "Protected") welke karakters hem kunnen dragen, met de suggestie: via de Warband Bank (warbound/WuE) of per mail (BoE die nog niet gebonden is). Bij soulbound staat er dat overdragen niet kan. Als het niet te bepalen is, zegt hij dat. Zo'n item wordt automatisch beschermd. De addon stuurt zelf nooit mail en verplaatst niets.

## Een nieuwe versie uitbrengen

Releases gaan automatisch via GitHub Actions ([.github/workflows/release.yml](.github/workflows/release.yml)) met de [BigWigs packager](https://github.com/BigWigsMods/packager):

```bash
git add -A
git commit -m "Beschrijving van de wijziging"
git tag -a v1.0.1 -m "v1.0.1"
git push --follow-tags
```

Bij elke tag die met `v` begint: tests draaien (`tests/run.py`, Lua 5.1 met een gesimuleerde WoW-API), de zip bouwen (`@project-version@` in de .toc wordt de tagnaam), uploaden naar CurseForge en een GitHub Release aanmaken. De changelog wordt gemaakt uit de commitberichten sinds de vorige tag. Een tag met `alpha` of `beta` erin (bijv. `v1.1.0-beta1`) wordt als alpha/beta-release geüpload.

Lokaal testen vóór een release: `pip install lupa` en dan `python tests/run.py`.
