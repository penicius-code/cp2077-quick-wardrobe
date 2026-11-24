// Cyberslop Quick Wardrobe 1.2.2 (2026-11-23; 1.2.0 2026-11-22): data bridge for the CET window
// 1.2.2: Build() returns -1 while Equipment-EX or the player is not ready (was 0 = an empty list kept for good).
// 1.2.1: a save made in mouse mode can't load with the camera held: vanilla NoCameraControl is savable, so one
// persistent bool remembers that mouse mode was on, and 1.5 s after a load the restrictions are removed again
// (by this mod's instigator, and by record ID when the save was made in mouse mode).
// "Cyberslop Quick Wardrobe". Reads and drives Equipment-EX 1.3.1 through its public API
// (OutfitSystem, ViewManager, InventoryHelper). No wraps, one persistent bool (1.2.1); nothing here
// runs unless the CET window calls it. 1.1.0: marked looks can be moved to the player stash.
// 1.2.0: mouse mode for the pinned window (overlay closed): raw mouse input through Codeware's
// Input/Key + Input/Axis callbacks, camera and weapons held by the game's own gameplay
// restrictions (Overlay Map's "Mouse only" method), released by the CET side, a watchdog, or a load.
import EquipmentEx.*

// 1.2.1: second cleanup after a load, once the restored status effects are surely in place
public class CyberslopQuickWardrobeLoadCleanup extends DelayCallback {
  public let system: wref<CyberslopQuickWardrobe>;
  public let savedOn: Bool;

  public func Call() {
    if IsDefined(this.system) {
      this.system.OnLoadCleanup(this.savedOn);
    }
  }
}

// mouse mode watchdog: lets go of the mouse when the CET side stops asking for input
public class CyberslopQuickWardrobeWatchdog extends DelayCallback {
  public let system: wref<CyberslopQuickWardrobe>;
  public let generation: Int32;

  public func Call() {
    if IsDefined(this.system) {
      this.system.OnWatchdog(this.generation);
    }
  }
}

public class CyberslopQuickWardrobeIndex extends IScriptable {
  public let index: Int32;
}

// one marked look during a move to the stash
public class CyberslopQuickWardrobeMove extends IScriptable {
  public let index: Int32;
  public let found: Bool;
  public let moved: Bool;
  public let kept: Bool;
}

public class CyberslopQuickWardrobe extends ScriptableSystem {
  // the list the window shows (one entry per look: entity + appearance, like Equipment-EX's own grid)
  private let m_items: array<ItemID>;
  private let m_names: array<String>;
  private let m_keys: array<String>;
  private let m_itemSlots: array<Int32>;
  private let m_visuals: ref<inkHashMap>;
  // Equipment-EX outfit slots, in its order
  private let m_slots: array<TweakDBID>;
  private let m_slotNames: array<String>;
  private let m_slotAreas: array<String>;
  // changes on every Build, so the CET side notices a new list (or a new session)
  private let m_token: Int32;
  private let m_rawCount: Int32;
  // list indices queued by the CET side for MoveListToStash
  private let m_moveList: array<Int32>;
  // mouse mode: input collected between two PullInput calls of the CET side
  private let m_mouse: Bool;
  private let m_inputHooked: Bool;
  private let m_dx: Float;
  private let m_dy: Float;
  private let m_wheel: Int32;
  private let m_left: Int32;
  private let m_right: Int32;
  private let m_beat: Int32;
  private let m_beatSeen: Int32;
  private let m_quiet: Int32;
  private let m_generation: Int32;
  // 1.2.1: true while mouse mode holds the camera, kept in the save (the only persistent field)
  private persistent let m_mouseSavedOn: Bool;

  private static func KnownSlots() -> array<String> = [
    "OutfitSlots.Head", "OutfitSlots.Balaclava",
    "OutfitSlots.Mask", "OutfitSlots.Glasses", "OutfitSlots.Eyes", "OutfitSlots.EyeLeft", "OutfitSlots.EyeRight", "OutfitSlots.Wreath",
    "OutfitSlots.EarLeft", "OutfitSlots.EarRight",
    "OutfitSlots.Neckwear", "OutfitSlots.NecklaceTight", "OutfitSlots.NecklaceShort", "OutfitSlots.NecklaceLong",
    "OutfitSlots.TorsoUnder", "OutfitSlots.TorsoInner", "OutfitSlots.TorsoMiddle", "OutfitSlots.TorsoOuter", "OutfitSlots.TorsoAux",
    "OutfitSlots.Back", "OutfitSlots.Waist",
    "OutfitSlots.ShoulderLeft", "OutfitSlots.ShoulderRight", "OutfitSlots.ElbowLeft", "OutfitSlots.ElbowRight", "OutfitSlots.WristLeft", "OutfitSlots.WristRight",
    "OutfitSlots.Hands", "OutfitSlots.HandLeft", "OutfitSlots.HandRight", "OutfitSlots.HandPropLeft", "OutfitSlots.HandPropRight",
    "OutfitSlots.FingersLeft", "OutfitSlots.FingersRight", "OutfitSlots.FingernailsLeft", "OutfitSlots.FingernailsRight",
    "OutfitSlots.LegsInner", "OutfitSlots.LegsMiddle", "OutfitSlots.LegsOuter", "OutfitSlots.ThighLeft", "OutfitSlots.ThighRight",
    "OutfitSlots.KneeLeft", "OutfitSlots.KneeRight", "OutfitSlots.AnkleLeft", "OutfitSlots.AnkleRight",
    "OutfitSlots.Feet",
    "OutfitSlots.ToesLeft", "OutfitSlots.ToesRight", "OutfitSlots.ToenailsLeft", "OutfitSlots.ToenailsRight",
    "OutfitSlots.BodyUnder", "OutfitSlots.BodyInner", "OutfitSlots.BodyMiddle", "OutfitSlots.BodyOuter"
  ];

  private static func KnownAreas() -> array<String> = [
    "Head", "Head",
    "Face", "Face", "Face", "Face", "Face", "Face",
    "Ears", "Ears",
    "Neck", "Neck", "Neck", "Neck",
    "Torso", "Torso", "Torso", "Torso", "Torso",
    "Back", "Waist",
    "Arms", "Arms", "Arms", "Arms", "Arms", "Arms",
    "Hands", "Hands", "Hands", "Hands", "Hands",
    "Fingers", "Fingers", "Fingers", "Fingers",
    "Legs", "Legs", "Legs", "Legs", "Legs",
    "Legs", "Legs", "Legs", "Legs",
    "Feet",
    "Toes", "Toes", "Toes", "Toes",
    "Body", "Body", "Body", "Body"
  ];

  private func Outfit() -> ref<OutfitSystem> {
    return OutfitSystem.GetInstance(this.GetGameInstance());
  }

  private func EnsureSlots(outfit: ref<OutfitSystem>) {
    if ArraySize(this.m_slots) > 0 {
      return;
    }
    let names = CyberslopQuickWardrobe.KnownSlots();
    let areas = CyberslopQuickWardrobe.KnownAreas();
    let known: array<TweakDBID>;
    for name in names {
      ArrayPush(known, TDBID.Create(name));
    }
    for slotID in outfit.GetOutfitSlots() {
      let k = ArrayFindFirst(known, slotID);
      ArrayPush(this.m_slots, slotID);
      ArrayPush(this.m_slotNames, outfit.GetSlotName(slotID));
      ArrayPush(this.m_slotAreas, (k >= 0 && k < ArraySize(areas)) ? areas[k] : "Other");
    }
  }

  // ---- list

  // 0 = wardrobe store, 1 = inventory + stash, 2 = inventory (Equipment-EX's own setting)
  public func GetSource() -> Int32 {
    let vm = ViewManager.GetInstance(this.GetGameInstance());
    return IsDefined(vm) ? EnumInt(vm.GetItemSource()) : 0;
  }

  public func SetSource(source: Int32) {
    let vm = ViewManager.GetInstance(this.GetGameInstance());
    if IsDefined(vm) && source >= 0 && source <= 2 {
      vm.SetItemSource(IntEnum<WardrobeItemSource>(source));
    }
  }

  private func SourceIDs(player: ref<PlayerPuppet>) -> array<ItemID> {
    let game = this.GetGameInstance();
    let ids: array<ItemID>;
    let source = this.GetSource();
    if source == 0 {
      ids = GameInstance.GetWardrobeSystem(game).GetStoredItemIDs();
      return ids;
    }
    let ts = GameInstance.GetTransactionSystem(game);
    let list: array<wref<gameItemData>>;
    ts.GetItemList(player, list);
    for data in list {
      if IsDefined(data) {
        ArrayPush(ids, data.GetID());
      }
    }
    if source == 1 {
      let helper = InventoryHelper.GetInstance(game);
      let stash: wref<Stash> = IsDefined(helper) ? helper.GetStash() : null;
      if IsDefined(stash) {
        let stashList: array<wref<gameItemData>>;
        ts.GetItemList(stash, stashList);
        for data in stashList {
          if IsDefined(data) {
            ArrayPush(ids, data.GetID());
          }
        }
      }
    }
    return ids;
  }

  // Clothing entries of the source (Equipment-EX preview copies not counted), so picking up
  // ammo or junk does not count as a change.
  private func CountClothing(ids: array<ItemID>) -> Int32 {
    if this.GetSource() == 0 {
      return ArraySize(ids); // the wardrobe store holds clothing only
    }
    let n = 0;
    for itemID in ids {
      if ItemID.IsValid(itemID) && !ItemID.HasFlag(itemID, gameEItemIDFlag.Preview)
        && IsDefined(TweakDBInterface.GetClothingRecord(ItemID.GetTDBID(itemID))) {
        n += 1;
      }
    }
    return n;
  }

  // Staleness check for the CET side (overlay open, and every 10 s while pinned).
  public func SourceCount() -> Int32 {
    let player = GetPlayer(this.GetGameInstance());
    if !IsDefined(player) {
      return -1;
    }
    return this.CountClothing(this.SourceIDs(player));
  }

  public func Build() -> Int32 {
    ArrayClear(this.m_items);
    ArrayClear(this.m_names);
    ArrayClear(this.m_keys);
    ArrayClear(this.m_itemSlots);
    this.m_visuals = new inkHashMap();
    this.m_token = RandRange(1, 2000000000);
    this.m_rawCount = 0;
    let outfit = this.Outfit();
    let player = GetPlayer(this.GetGameInstance());
    if !IsDefined(outfit) || !IsDefined(player) {
      return -1;   // 1.2.2: not ready (the CET side asks again)
    }
    this.EnsureSlots(outfit);
    let ids = this.SourceIDs(player);
    this.m_rawCount = this.CountClothing(ids);
    for itemID in ids {
      this.AddItem(outfit, itemID);
    }
    return ArraySize(this.m_items);
  }

  private func VisualKey(record: ref<Item_Record>) -> String {
    let entity = NameToString(record.EntityName());
    let appearance = NameToString(record.AppearanceName());
    if StrLen(entity) == 0 && StrLen(appearance) == 0 {
      return TDBID.ToStringDEBUG(record.GetID());
    }
    return entity + "|" + appearance;
  }

  private func ItemName(record: ref<Item_Record>) -> String {
    let name = GetLocalizedItemNameByCName(record.DisplayName());
    if StrLen(name) == 0 {
      name = GetLocalizedTextByKey(record.DisplayName());
    }
    if StrLen(name) == 0 {
      name = TDBID.ToStringDEBUG(record.GetID());
    }
    return name;
  }

  private func AddItem(outfit: ref<OutfitSystem>, itemID: ItemID) {
    if !ItemID.IsValid(itemID) || ItemID.HasFlag(itemID, gameEItemIDFlag.Preview) {
      return;
    }
    let record = TweakDBInterface.GetClothingRecord(ItemID.GetTDBID(itemID));
    if !IsDefined(record) || !outfit.IsEquippable(itemID) {
      return;
    }
    let slotIndex = ArrayFindFirst(this.m_slots, outfit.GetItemSlot(itemID));
    if slotIndex < 0 {
      return;
    }
    let key = this.VisualKey(record);
    let hash = TDBID.ToNumber(TDBID.Create(key));
    if this.m_visuals.KeyExist(hash) {
      // same look already listed: keep the copy that is worn, if this is it
      let existing = this.m_visuals.Get(hash) as CyberslopQuickWardrobeIndex;
      if IsDefined(existing) && outfit.IsEquipped(itemID) {
        this.m_items[existing.index] = itemID;
      }
      return;
    }
    let entry = new CyberslopQuickWardrobeIndex();
    entry.index = ArraySize(this.m_items);
    this.m_visuals.Insert(hash, entry);
    ArrayPush(this.m_items, itemID);
    ArrayPush(this.m_names, this.ItemName(record));
    ArrayPush(this.m_keys, key);
    ArrayPush(this.m_itemSlots, slotIndex);
  }

  public func GetToken() -> Int32 = this.m_token;
  public func GetRawCount() -> Int32 = this.m_rawCount;
  public func GetNames() -> array<String> = this.m_names;
  public func GetKeys() -> array<String> = this.m_keys;
  public func GetItemSlots() -> array<Int32> = this.m_itemSlots;
  public func GetSlotNames() -> array<String> = this.m_slotNames;
  public func GetSlotAreas() -> array<String> = this.m_slotAreas;

  // ---- state

  private func IndexOfRecord(recordID: TweakDBID) -> Int32 {
    if !IsDefined(this.m_visuals) {
      return -1;
    }
    let record = TweakDBInterface.GetItemRecord(recordID);
    if !IsDefined(record) {
      return -1;
    }
    let hash = TDBID.ToNumber(TDBID.Create(this.VisualKey(record)));
    if !this.m_visuals.KeyExist(hash) {
      return -1;
    }
    let entry = this.m_visuals.Get(hash) as CyberslopQuickWardrobeIndex;
    return IsDefined(entry) ? entry.index : -1;
  }

  // Index of the list entry shown in an outfit slot right now, -1 if none (or not spawned yet).
  private func ShownIndex(player: ref<PlayerPuppet>, slotID: TweakDBID) -> Int32 {
    let obj = GameInstance.GetTransactionSystem(this.GetGameInstance()).GetItemInSlot(player, slotID);
    if !IsDefined(obj) {
      return -1;
    }
    return this.IndexOfRecord(ItemID.GetTDBID(obj.GetItemID()));
  }

  // [token, outfit active 0/1, blocked 0/1, equipped list indices...]
  public func Poll() -> array<Int32> {
    let out: array<Int32>;
    ArrayPush(out, this.m_token);
    let outfit = this.Outfit();
    let player = GetPlayer(this.GetGameInstance());
    if !IsDefined(outfit) || !IsDefined(player) {
      ArrayPush(out, 0);
      ArrayPush(out, 1);
      return out;
    }
    let active = outfit.IsActive();
    ArrayPush(out, active ? 1 : 0);
    ArrayPush(out, outfit.IsBlocked() ? 1 : 0);
    if active {
      for slotID in outfit.GetUsedSlots() {
        let idx = this.ShownIndex(player, slotID);
        if idx >= 0 {
          ArrayPush(out, idx);
        }
      }
    }
    return out;
  }

  // 1 = put on, 0 = taken off, -1 = refused (quest outfit, Equipment-EX disabled, bad index)
  public func Toggle(index: Int32) -> Int32 {
    if index < 0 || index >= ArraySize(this.m_items) {
      return -1;
    }
    let outfit = this.Outfit();
    let player = GetPlayer(this.GetGameInstance());
    if !IsDefined(outfit) || !IsDefined(player) || outfit.IsBlocked() {
      return -1;
    }
    let itemID = this.m_items[index];
    let slotID = outfit.GetItemSlot(itemID);
    if !outfit.IsActive() && ArraySize(outfit.GetUsedSlots()) > 0 {
      // Outfit off: bring the last outfit back first (same as the window's "Outfit: on"),
      // instead of EquipItem's clone of the real equipment, which would discard it.
      // An item that is part of that outfit stays on.
      outfit.Reactivate();
      if outfit.IsActive() && outfit.IsEquipped(itemID) {
        return 1;
      }
    }
    if outfit.IsActive() && outfit.IsOccupied(slotID) {
      if outfit.IsEquipped(itemID) || this.ShownIndex(player, slotID) == index {
        return outfit.UnequipSlot(slotID) ? 0 : -1;
      }
    }
    return outfit.EquipItem(itemID) ? 1 : -1;
  }

  public func IsOutfitActive() -> Bool {
    let outfit = this.Outfit();
    return IsDefined(outfit) && outfit.IsActive();
  }

  // Off = Equipment-EX steps aside and V's real equipment shows. On = the last outfit state
  // comes back (or, if it is empty, the current equipment is copied, like Equipment-EX does).
  public func SetOutfitActive(on: Bool) -> Bool {
    let outfit = this.Outfit();
    if !IsDefined(outfit) {
      return false;
    }
    if !on {
      outfit.Deactivate();
      return true;
    }
    if outfit.IsBlocked() {
      return false;
    }
    if ArraySize(outfit.GetUsedSlots()) > 0 {
      outfit.Reactivate();
    } else {
      outfit.Activate();
    }
    return outfit.IsActive();
  }

  public func UnequipAll() -> Bool {
    let outfit = this.Outfit();
    if !IsDefined(outfit) || outfit.IsBlocked() {
      return false;
    }
    outfit.UnequipAll();
    return true;
  }

  // ---- saved outfits (Equipment-EX's list, sorted by name)

  public func GetOutfitNames() -> array<String> {
    let out: array<String>;
    let outfit = this.Outfit();
    if IsDefined(outfit) {
      for name in outfit.GetOutfits() {
        ArrayPush(out, NameToString(name));
      }
    }
    return out;
  }

  // the saved outfit that matches what is worn right now ("" if none; GetLastUsedOutfit can be stale)
  public func GetCurrentOutfit() -> String {
    let outfit = this.Outfit();
    if !IsDefined(outfit) || !outfit.IsActive() {
      return "";
    }
    for name in outfit.GetOutfits() {
      if outfit.IsEquipped(name) {
        return NameToString(name);
      }
    }
    return "";
  }

  public func LoadOutfit(name: String) -> Bool {
    let outfit = this.Outfit();
    return IsDefined(outfit) && StrLen(name) > 0 && outfit.LoadOutfit(StringToName(name));
  }

  // ---- mouse mode (pinned window, overlay closed)

  private static func MouseInstigator() -> TweakDBID = t"CyberslopQuickWardrobe.Mouse";

  // a save made in mouse mode must not load with the camera held
  private func OnPlayerAttach(request: ref<PlayerAttachRequest>) {
    let cb: ref<CyberslopQuickWardrobeLoadCleanup>;
    this.m_mouse = false;
    this.RemoveMouseRestrictions(request.owner);
    // 1.2.1: again 1.5 s later (the restored effects may arrive after the attach)
    cb = new CyberslopQuickWardrobeLoadCleanup();
    cb.system = this;
    cb.savedOn = this.m_mouseSavedOn;
    GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(cb, 1.5, false);
  }

  public func OnLoadCleanup(savedOn: Bool) {
    let player: ref<PlayerPuppet>;
    if this.m_mouse {
      return;
    }
    player = GetPlayer(this.GetGameInstance());
    if !IsDefined(player) {
      return;
    }
    this.RemoveMouseRestrictions(player);
    if savedOn {
      // the save was made in mouse mode: the instigator may not survive the save, so remove by record ID too
      if StatusEffectSystem.ObjectHasStatusEffect(player, t"GameplayRestriction.NoCameraControl") {
        StatusEffectHelper.RemoveStatusEffect(player, t"GameplayRestriction.NoCameraControl");
        FTLog("[CyberslopQuickWardrobe] save made in mouse mode: camera lock from the save removed");
      }
      if StatusEffectSystem.ObjectHasStatusEffect(player, t"GameplayRestriction.NoWeapons") {
        StatusEffectHelper.RemoveStatusEffect(player, t"GameplayRestriction.NoWeapons");
      }
    }
    this.m_mouseSavedOn = false;
  }

  // On: the camera stays still and the mouse buttons / wheel don't reach V's weapons
  // (GameplayRestriction.NoCameraControl + NoWeapons); the keyboard stays V's.
  public func SetMouse(on: Bool) -> Bool {
    let player = GetPlayer(this.GetGameInstance());
    if !on || !IsDefined(player) {
      this.ReleaseMouse();
      return false;
    }
    if !this.m_inputHooked {
      GameInstance.GetCallbackSystem().RegisterCallback(n"Input/Key", this, n"OnQuickWardrobeKey");
      GameInstance.GetCallbackSystem().RegisterCallback(n"Input/Axis", this, n"OnQuickWardrobeAxis");
      this.m_inputHooked = true;
    }
    if !this.m_mouse {
      this.m_mouse = true;
      this.m_dx = 0.0;
      this.m_dy = 0.0;
      this.m_wheel = 0;
      this.m_left = 0;
      this.m_right = 0;
      this.m_quiet = 0;
      this.m_beatSeen = this.m_beat;
      this.m_generation += 1;
      StatusEffectHelper.ApplyStatusEffect(player, t"GameplayRestriction.NoCameraControl", CyberslopQuickWardrobe.MouseInstigator());
      StatusEffectHelper.ApplyStatusEffect(player, t"GameplayRestriction.NoWeapons", CyberslopQuickWardrobe.MouseInstigator());
      this.m_mouseSavedOn = true;
      this.ScheduleWatchdog();
    }
    return true;
  }

  private func ReleaseMouse() {
    this.m_mouse = false;
    this.m_mouseSavedOn = false;
    this.RemoveMouseRestrictions(GetPlayer(this.GetGameInstance()));
  }

  private func RemoveMouseRestrictions(player: ref<GameObject>) {
    if !IsDefined(player) {
      return;
    }
    let ses = GameInstance.GetStatusEffectSystem(player.GetGame());
    let applied: array<ref<StatusEffect>>;
    ses.GetAppliedEffects(player.GetEntityID(), applied);
    for e in applied {
      if IsDefined(e) && e.GetInstigatorStaticDataID() == CyberslopQuickWardrobe.MouseInstigator() {
        ses.RemoveStatusEffect(player.GetEntityID(), e.GetRecord().GetID(), e.GetStackCount());
      }
    }
  }

  // [mouse mode on 0/1, mouse x counts, mouse y counts (down +), wheel notches (up +), left presses,
  // right presses] since the last call; also the CET side's heartbeat for the watchdog
  public func PullInput() -> array<Int32> {
    this.m_beat += 1;
    let out: array<Int32>;
    let dx = Cast<Int32>(this.m_dx);
    let dy = Cast<Int32>(this.m_dy);
    this.m_dx -= Cast<Float>(dx);
    this.m_dy -= Cast<Float>(dy);
    ArrayPush(out, this.m_mouse ? 1 : 0);
    ArrayPush(out, dx);
    ArrayPush(out, dy);
    ArrayPush(out, this.m_wheel);
    ArrayPush(out, this.m_left);
    ArrayPush(out, this.m_right);
    this.m_wheel = 0;
    this.m_left = 0;
    this.m_right = 0;
    return out;
  }

  private cb func OnQuickWardrobeKey(evt: ref<KeyInputEvent>) {
    if !this.m_mouse || NotEquals(evt.GetAction(), EInputAction.IACT_Press) {
      return;
    }
    let key = evt.GetKey();
    if Equals(key, EInputKey.IK_LeftMouse) {
      this.m_left += 1;
    } else {
      if Equals(key, EInputKey.IK_RightMouse) {
        this.m_right += 1;
      }
    }
  }

  private cb func OnQuickWardrobeAxis(evt: ref<AxisInputEvent>) {
    if !this.m_mouse {
      return;
    }
    let key = evt.GetKey();
    if Equals(key, EInputKey.IK_MouseX) {
      this.m_dx += evt.GetValue();
    } else {
      if Equals(key, EInputKey.IK_MouseY) {
        this.m_dy += evt.GetValue();
      } else {
        if Equals(key, EInputKey.IK_MouseZ) && evt.GetValue() != 0.0 {
          this.m_wheel += evt.GetValue() > 0.0 ? 1 : -1;
        }
      }
    }
  }

  private func ScheduleWatchdog() {
    let cb = new CyberslopQuickWardrobeWatchdog();
    cb.system = this;
    cb.generation = this.m_generation;
    GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(cb, 0.5, false);
  }

  // every 0.5 s while on: no PullInput for 3 checks in a row (CET reloaded, window gone) -> let go
  public func OnWatchdog(generation: Int32) {
    if !this.m_mouse || generation != this.m_generation {
      return;
    }
    if this.m_beat == this.m_beatSeen {
      this.m_quiet += 1;
    } else {
      this.m_quiet = 0;
      this.m_beatSeen = this.m_beat;
    }
    if this.m_quiet >= 3 {
      this.ReleaseMouse();
      return;
    }
    this.ScheduleWatchdog();
  }

  // ---- marked looks -> player stash

  public func ClearMoveList() {
    ArrayClear(this.m_moveList);
  }

  public func AddToMoveList(index: Int32) {
    if index >= 0 && index < ArraySize(this.m_keys) && !ArrayContains(this.m_moveList, index) {
      ArrayPush(this.m_moveList, index);
    }
  }

  // The stash in reach: the stash device Equipment-EX registered (set when one streams in, gone
  // when it streams out again), else the player's own vehicle V sits in: the vanilla trunk menu
  // opens the shared stash on that vehicle object (VehicleComponent.OnVehiclePlayerTrunk), offered
  // only for player vehicles without the NoTrunk visual tag (VehicleComponentPS.GetTrunkActions).
  private func StashTarget(player: ref<PlayerPuppet>) -> ref<GameObject> {
    let game = this.GetGameInstance();
    let helper = InventoryHelper.GetInstance(game);
    if IsDefined(helper) {
      let stash: ref<Stash> = helper.GetStash();
      if IsDefined(stash) && stash.IsAttached() {
        return stash;
      }
    }
    let vehicle: wref<VehicleObject>;
    if VehicleComponent.GetVehicle(game, player, vehicle) && IsDefined(vehicle) && vehicle.IsPlayerVehicle()
      && !vehicle.MatchVisualTag(n"NoTrunk") {
      let target: ref<GameObject> = vehicle;
      return target;
    }
    return null;
  }

  public func StashInReach() -> Bool {
    let player = GetPlayer(this.GetGameInstance());
    return IsDefined(player) && IsDefined(this.StashTarget(player));
  }

  // Moves every inventory copy of the queued looks to the stash; worn ones (outfit or real
  // equipment) and quest / stash-blacklisted ones stay. Clears the queue.
  // [status, moved, kept worn, kept quest, failed, looks not in the inventory, list indices of
  // looks moved completely...]; status 0 = done, -1 = no stash in reach, -2 = not ready.
  public func MoveListToStash() -> array<Int32> {
    let out: array<Int32>;
    let game = this.GetGameInstance();
    let player = GetPlayer(game);
    let outfit = this.Outfit();
    if !IsDefined(player) || !IsDefined(outfit) || !IsDefined(this.m_visuals) || ArraySize(this.m_moveList) == 0 {
      ArrayClear(this.m_moveList);
      ArrayPush(out, -2);
      return out;
    }
    let target = this.StashTarget(player);
    if !IsDefined(target) {
      ArrayClear(this.m_moveList);
      ArrayPush(out, -1);
      return out;
    }
    // look hash -> queued look
    let marked = new inkHashMap();
    let looks: array<ref<CyberslopQuickWardrobeMove>>;
    for index in this.m_moveList {
      let hash = TDBID.ToNumber(TDBID.Create(this.m_keys[index]));
      if !marked.KeyExist(hash) {
        let look = new CyberslopQuickWardrobeMove();
        look.index = index;
        marked.Insert(hash, look);
        ArrayPush(looks, look);
      }
    }
    ArrayClear(this.m_moveList);

    // pick the copies first, move them after: the inventory must not change while it is read
    let ts = GameInstance.GetTransactionSystem(game);
    let equipment = EquipmentSystem.GetData(player);
    let blacklist = UIInventoryItemsManager.GetStashBlacklistedTags();
    let list: array<wref<gameItemData>>;
    ts.GetItemList(player, list);
    let ids: array<ItemID>;
    let amounts: array<Int32>;
    let owners: array<ref<CyberslopQuickWardrobeMove>>;
    let keptWorn = 0;
    let keptQuest = 0;
    for data in list {
      let look = this.MarkedLook(data, marked);
      if IsDefined(look) {
        look.found = true;
        let itemID = data.GetID();
        if outfit.IsEquipped(itemID) || (IsDefined(equipment) && equipment.IsEquipped(itemID)) {
          look.kept = true;
          keptWorn += 1;
        } else {
          if data.HasTag(n"Quest") || data.HasAnyOfTags(blacklist) {
            look.kept = true;
            keptQuest += 1;
          } else {
            if data.GetQuantity() > 0 {
              ArrayPush(ids, itemID);
              ArrayPush(amounts, data.GetQuantity());
              ArrayPush(owners, look);
            }
          }
        }
      }
    }

    let moved = 0;
    let failed = 0;
    let i = 0;
    while i < ArraySize(ids) {
      if ts.TransferItem(player, target, ids[i], amounts[i]) {
        moved += 1;
        owners[i].moved = true;
      } else {
        failed += 1;
        owners[i].kept = true;
      }
      i += 1;
    }
    let notFound = 0;
    for look in looks {
      if !look.found {
        notFound += 1;
      }
    }
    ArrayPush(out, 0);
    ArrayPush(out, moved);
    ArrayPush(out, keptWorn);
    ArrayPush(out, keptQuest);
    ArrayPush(out, failed);
    ArrayPush(out, notFound);
    for look in looks {
      if look.moved && !look.kept {
        ArrayPush(out, look.index);
      }
    }
    return out;
  }

  // the queued look an inventory entry belongs to (real clothing only, no preview copies)
  private func MarkedLook(data: wref<gameItemData>, marked: ref<inkHashMap>) -> ref<CyberslopQuickWardrobeMove> {
    if !IsDefined(data) {
      return null;
    }
    let itemID = data.GetID();
    if !ItemID.IsValid(itemID) || ItemID.HasFlag(itemID, gameEItemIDFlag.Preview) {
      return null;
    }
    let record = TweakDBInterface.GetClothingRecord(ItemID.GetTDBID(itemID));
    if !IsDefined(record) {
      return null;
    }
    let hash = TDBID.ToNumber(TDBID.Create(this.VisualKey(record)));
    if !marked.KeyExist(hash) {
      return null;
    }
    return marked.Get(hash) as CyberslopQuickWardrobeMove;
  }

  // false if the name is taken (Equipment-EX keeps the old one) or empty
  public func SaveOutfit(name: String) -> Bool {
    let outfit = this.Outfit();
    if !IsDefined(outfit) || StrLen(name) == 0 || outfit.HasOutfit(StringToName(name)) {
      return false;
    }
    return outfit.SaveOutfit(StringToName(name), false);
  }
}
