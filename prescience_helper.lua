local db_defaults = {
  unit_frames_frame = {
    point = "CENTER",
    relativeFrame = nil,
    relativePoint = "CENTER",
    ofsx = 0,
    ofsy = 0,
    width = 750,
    height = 400,
  }
}

local GCD_BASE = 1.500;

local PRESCIENCE_DURATION = 18;

local INTERWOVEN_THREADS_ID = 412713;
local PRESCIENCE_SPELL_ID = 409311;
local PRESCIENCE_NAME = "Prescience";
local EBON_MIGHT_SPELL_ID = 395152;
local EBON_MIGHT_NAME = "Ebon Might";
local EBON_MIGHT_CAST_TIME = 1.500;

local DEFAULT_EBON_MIGHT_DURATION = 21.600;

local CURRENT_VERSION = "2";

Prescience_helper = CreateFrame("Frame")

local function un_base85(from)
  local returning = {};
  local value = 0;
  local i = 1;
  local len = strlen(from);
  while i<=len do
    if strbyte(from,i) == 122 then
      for j=0,3 do
        tinsert(returning,0);
      end
      i = i + 1;
    else
      if i + 4 > len then
        return {};
      end
      value = 0;
      for j=0,4 do
        value = value * 85 + (strbyte(from, i+4-j) - 32);
      end
      for j=0,3 do
        tinsert(returning,bit.band(0xFF, bit.rshift(value,j*8)))
      end
      i = i + 5;
    end
  end
  return returning;
end

local function to_uint(bytes, offset, length)
  local returning = 0;
  for i=0,length-1 do
    returning = bit.bor(returning, bit.lshift(bytes[offset+i],i*8));
  end
  return returning;
end

local function to_player_guid(bytes, offset)
  local server_id = to_uint(bytes,offset,2);
  local player_uid = to_uint(bytes,offset+2,4);

  return string.format("Player-%d-%08X",server_id,player_uid);
end

local function copy_table(from, into, overwrite)
  for k,v in pairs(from) do
    if overwrite or into[k] == nil then
      into[k] = v;
    end
  end
end

function Prescience_helper:on_event(event, ...)
  Prescience_helper[event](self, ...);
end

Prescience_helper:RegisterEvent("ADDON_LOADED");
Prescience_helper:RegisterEvent("ENCOUNTER_START");
Prescience_helper:RegisterEvent("ENCOUNTER_END");
Prescience_helper:RegisterEvent("PLAYER_LEAVING_WORLD");
Prescience_helper:RegisterEvent("GROUP_ROSTER_UPDATE");
Prescience_helper:RegisterEvent("INSPECT_READY");
Prescience_helper:RegisterEvent("PLAYER_LOGIN");
Prescience_helper:RegisterEvent("UNIT_AURA");
Prescience_helper:RegisterEvent("SPELL_UPDATE_COOLDOWN");
Prescience_helper:SetScript("OnEvent", Prescience_helper.on_event);

local function make_clean_state()
  return {
      prescience = {
        on={},
        charge1 = 0,
        charge2 = 0
      },
      ebon_might = {
        on={},
        ready = 0
      }
    };
end

local function calc_damage(damage, with_ebon, with_prescience, with_shifting_sands)
  local returning = damage.base;

  if with_ebon then
    returning = returning * damage.ebon_mult;
  end
  if with_prescience then
    returning = returning * damage.prescience_mult;
  end
  if with_shifting_sands then
    returning = returning * damage.shifting_sands_mult;
  end

  return returning - damage.base;
end

local function calc_damage_range(damages, start_time, end_time, with_ebon, with_prescience, with_shifting_sands)
  local start_index = 1;

  local damages_len = #damages;

  if damages_len == 0 then
    return 0;
  end

  --find start calced damage
  for i,v in ipairs(damages) do
    if v.time_at <= start_time then
      start_index = i;
    else
      break;
    end
  end

  local end_index = start_index;

  for i=start_index+1,damages_len do
    if damages[i].time_at <= end_time then
      end_index = i;
    else
      break;
    end
  end

  if start_index == end_index then
    return calc_damage(damages[start_index],with_ebon,with_prescience,with_shifting_sands) * (end_time - start_time);
  end
    local returning = 0;
  local prev_time = start_time;

  for i=start_index,end_index-1 do
    returning = returning + calc_damage(damages[i],with_ebon,with_prescience,with_shifting_sands) * (damages[i+1].time_at-prev_time);
    prev_time = damages[i+1].time_at;
  end
  returning = returning + calc_damage(damages[end_index],with_ebon,with_prescience,with_shifting_sands)*(end_time-damages[end_index].time_at);

  return returning;
end

local function make_colour(rgb, alpha) 
  return {
    r=rgb.r,
    g=rgb.g,
    b=rgb.b,
    a=alpha
  };
end

local NORMAL_ALPHA = 1;
local OUT_OF_RANGE_ALPHA = 0.6;
local IGNORE_ALPHA = 0.3;
local DEAD_ALPHA = 0.1;

local IGNORE_RGB = {r=0.3,g=0.3,b=0.3};
local DEAD_RGB= {r=0,g=0,b=0};
local BEST_RGB = {r=0,g=1,b=0};
local BEST_LOCAL_RGB = {r=1,g=1,b=0};

local DEAD_COLOUR = make_colour(DEAD_RGB,DEAD_ALPHA);
local IGNORE_COLOUR = make_colour(IGNORE_RGB,IGNORE_ALPHA);
local BEST_LOCAL_COLOUR = make_colour(BEST_LOCAL_RGB, NORMAL_ALPHA);

function Prescience_helper:ADDON_LOADED(addon_name)
  if addon_name == "Prescience_helper" then
    --set up db
    prescience_helper_db = prescience_helper_db or {}
    self.db = prescience_helper_db;
    copy_table(db_defaults, self.db, false);

    --set up state
    self.members = {};
    self.configs = {};
    self.state = make_clean_state();
    self.start_time = 0;
    self.in_encounter = false;
    self.queue_update = false;
    self.player_guid = UnitGUID("player");
    local player_name,_ = UnitNameUnmodified("player");
    self.members[self.player_guid] = { --set up player's info
      spec = 1473, --It's us, we should be an aug (otherwise why are using this addon?)
      slot="player",
      name=player_name,
      player=true
    };

    --set up unit frames parent
    self.unitFramesParent = CreateFrame("Frame","ph_unit_frames_parent",Prescience_helper);
    self.unitFramesParent:SetPoint(
      self.db.unit_frames_frame.point,
      self.db.unit_frames_frame.relativeFrame,
      self.db.unit_frames_frame.relativePoint,
      self.db.unit_frames_frame.ofsx,
      self.db.unit_frames_frame.ofsy
    );
    self.unitFramesParent:SetSize(
      self.db.unit_frames_frame.width,
      self.db.unit_frames_frame.height);
    
    self.unitFramesParent.texture = self.unitFramesParent:CreateTexture();
    self.unitFramesParent.texture:SetAllPoints(self.unitFramesParent);
    self.unitFramesParent.texture:SetColorTexture(0,0,0,1);
    self.unitFramesParent:SetMovable(true);
    self.unitFramesParent:SetClampedToScreen(false);
    self.unitFramesParent:SetResizable(true)
    self.unitFramesParent:SetResizeBounds(150, 100, nil, nil)
    self.unitFramesParent:Hide();
    self.unitFramesParent:SetScript("OnMouseDown", function(self, button)
      if button == "LeftButton" then
        self:StartMoving();
      elseif button == "RightButton" then
        self:StartSizing("BOTTOMRIGHT");
      end
    end);
    self.unitFramesParent:SetScript("OnMouseUp", function(self, _)
      self:StopMovingOrSizing()
      local point, relativeFrame, relativeTo, ofsx, ofsy = self:GetPoint()
      Prescience_helper.db.unit_frames_frame.point = point;
      Prescience_helper.db.unit_frames_frame.relativeFrame = relativeFrame;
      Prescience_helper.db.unit_frames_frame.relativePoint = relativeTo;
      Prescience_helper.db.unit_frames_frame.ofsx = ofsx;
      Prescience_helper.db.unit_frames_frame.ofsy = ofsy;
      Prescience_helper.db.unit_frames_frame.width = self:GetWidth();
      Prescience_helper.db.unit_frames_frame.height = self:GetHeight();
      Prescience_helper:layout();
    end);

    --set up input/output frame
    self.settings_frame = CreateFrame("Frame", "PrescienceHelperFrame", Prescience_helper, "DialogBoxFrame");
    self.settings_frame:ClearAllPoints();
    self.settings_frame:SetPoint(
      "CENTER",
      nil,
      "CENTER",
      0,
      0)
    self.settings_frame:SetSize(750, 400)
    self.settings_frame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\PVPFrame\\UI-Character-PVP-Highlight",
      edgeSize = 16,
      insets = { left = 8, right = 8, top = 8, bottom = 8 }});
    self.settings_frame:SetMovable(true);
    self.settings_frame:SetClampedToScreen(true);

    local settings_scroll_frame = CreateFrame("ScrollFrame", "PrescienceHelperScrollFrame", self.settings_frame, "UIPanelScrollFrameTemplate")
    settings_scroll_frame:SetPoint("LEFT", 16, 0)
    settings_scroll_frame:SetPoint("RIGHT", -32, 0)
    settings_scroll_frame:SetPoint("TOP", 0, -32)
    --settings_scroll_frame:SetPoint("BOTTOM", PrescienceHelperScrollFrameButton, "TOP", 0, 0)

    self.settings_edit_box = CreateFrame("EditBox", "PrescienceHelperEditBox", settings_scroll_frame)
    self.settings_edit_box:SetSize(settings_scroll_frame:GetSize())
    self.settings_edit_box:SetMultiLine(true)
    self.settings_edit_box:SetAutoFocus(true)
    self.settings_edit_box:SetFontObject("ChatFontNormal")
    self.settings_edit_box:SetScript("OnEscapePressed", function() self.settings_frame:Hide() end)
    settings_scroll_frame:SetScrollChild(self.settings_edit_box)

    self.settings_frame:SetResizable(true)
    self.settings_frame:SetResizeBounds(150, 100, nil, nil)

    local settings_resize_button = CreateFrame("Button", "PrescienceHelperResizeButton", self.settings_frame)
    settings_resize_button:SetPoint("BOTTOMRIGHT", -6, 7)
    settings_resize_button:SetSize(16, 16)

    settings_resize_button:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    settings_resize_button:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    settings_resize_button:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

    settings_resize_button:SetScript("OnMouseDown", function(self, button)
      if button == "LeftButton" then
        self.settings_frame:StartSizing("BOTTOMRIGHT")
        self:GetHighlightTexture():Hide()
      end
    end)
    settings_resize_button:SetScript("OnMouseUp", function(self, _)
        self.settings_frame:StopMovingOrSizing()
        self:GetHighlightTexture():Show()
        self.settings_edit_box:SetWidth(settings_scroll_frame:GetWidth())
    end)

    self.settings_frame:SetScript("OnHide", function() Prescience_helper:on_input(self.settings_edit_box:GetText()); end);

    self.unit_frames = {};

    for i=1,MAX_RAID_MEMBERS do
      local new_button = CreateFrame("Button", nil,nil, "SecureUnitButtonTemplate");

      new_button.texture = new_button:CreateTexture(nil,'ARTWORK');
      new_button.texture:SetAllPoints(new_button);
      new_button.texture:SetColorTexture(1,1,1);

      --new_button.border = new_button:CreateTexture(nil,'BORDER');
      --new_button.border:SetAllPoints(new_button);
      --new_button.border:SetColorTexture(0,0,0);

      new_button.name = new_button:CreateFontString(nil,'ARTWORK',"GameTooltipText");
      new_button.name:SetPoint("CENTER");
      new_button.name:SetTextColor(0,0,0);

      new_button:SetAttribute("type","target");
      new_button:Hide();
      tinsert(self.unit_frames,new_button);
    end

    --self.timer = C_Timer.NewTicker(0.25,function() Prescience_helper:tick(); end);
    self:tick();
  end
end

function Prescience_helper:start_fight()
  self.in_encounter = true;
  self.start_time = GetTime();
  self:update_prescience_cooldown();
  self:update_ebon_might_cooldown();
  self:tick();
end

function Prescience_helper:ENCOUNTER_START(encounterID, encounterName, difficultyID, groupSize)
  self:start_fight();
end

function Prescience_helper:force_roster()
  for guid,config in pairs(self.configs) do
    if config.slot == nil then
      config.slot = "player";
      config.unit_frame:SetAttribute("unit","player");
    end
  end
  self:tick();
end

function Prescience_helper:update_roster()
  local in_combat_lockdown = InCombatLockdown();

  local removing = {};

  for guid,member in pairs(self.members) do
    if not member.player then
      removing[guid] = true;
    end
  end

  for i = 1,MAX_RAID_MEMBERS do --for every member of the group
    local checking = "raid"..i; 
    if UnitExists(checking) then --if they exist
      local guid = UnitGUID(checking);
      if guid ~= self.player_guid then
        local name,_ = UnitNameUnmodified(checking);

        removing[guid] = false;

        local found_member = self.members[guid];
        if found_member == nil then
          found_member = { --set up the info
            spec = -1,
            player = false
          };
          self.members[guid] = found_member;
        end

        found_member.slot = checking;
        found_member.name = name;

        local found_config = self.configs[guid];

        if found_config ~= nil then
          found_config.slot = checking;
          found_config.unit_frame.name:SetText(name);
          if not in_combat_lockdown then
            found_config.unit_frame:SetAttribute("unit",checking);
          end
        end
      end
    end
  end

  local removed = {};

  for guid,v in pairs(removing) do
    if v then
      local found_config = self.configs[guid];
      if found_config ~= nil then
        found_config.slot = nil;
        if not in_combat_lockdown then
          found_config.unit_frame:SetAttribute("unit","");
        end
      end
      self.members[guid] = nil;
    end
  end
end

function Prescience_helper:tick()
  if self.timer ~= nil and not self.timer:IsCancelled() then
    self.timer:Cancel();
  end
  --CALC COLOURS
  local haste = GetHaste() + 1;
  local gcd = GCD_BASE / haste;
  local eb_cast_time = EBON_MIGHT_CAST_TIME / haste;

  local _,current_gcd = GetSpellCooldown(61304);

  local p1 = self.state.prescience.charge1;
  local p2 = self.state.prescience.charge2;
  local next_eb_hit = self.state.ebon_might.ready + eb_cast_time;

  local time = GetTime();
  local time_base = time;
  if self.in_encounter then
    time_base = self.start_time;
  end

  local next_interesting_event = 0.25;

  local next_free_action = time+current_gcd;

  if p2 <= next_free_action then
    p2 = next_free_action;
    next_free_action = next_free_action + gcd;
  end
  if p1 <= next_free_action then
    p1 = next_free_action;
    next_free_action = next_free_action + gcd;
  end
  if next_eb_hit <= next_free_action+eb_cast_time then
    next_eb_hit = next_free_action+eb_cast_time;
    next_free_action = next_eb_hit + max(eb_cast_time,gcd);
  end
  
  local eb_gains = {};

  local colours = {};

  for guid,config in pairs(self.configs) do
    if config.slot ~= nil and not UnitIsDead(config.slot) then
      local can_be_eboned = guid ~= self.player_guid;
      local eb_info = {
        val=calc_damage_range(config.damages,next_eb_hit - time_base,DEFAULT_EBON_MIGHT_DURATION,can_be_eboned,false,false),
        guid=guid,
        slot=config.slot
      };
      tinsert(eb_gains, eb_info);

      colours[guid] = IGNORE_COLOUR;
    else
      colours[guid] = DEAD_COLOUR;
    end
  end

  table.sort(eb_gains,function(a,b) return a.val > b.val; end);

  local found_best = false;
  for _,eb_info in ipairs(eb_gains) do
    local doesnt_have_prescience_for_next_em = self.state.prescience.on[eb_info.guid] == nil or self.state.prescience.on[eb_info.guid].expires < next_eb_hit;
    if self.state.prescience.on[eb_info.guid] ~= nil and self.state.prescience.on[eb_info.guid].expires > time then
      next_interesting_event = min(next_interesting_event, self.state.prescience.on[eb_info.guid].expires - time);
    end
    if not eb_info.is_dead and doesnt_have_prescience_for_next_em  then --if we're not dead and we don't have prescience that'll last until the next ebon might
      local in_range = IsSpellInRange(PRESCIENCE_NAME, eb_info.slot) == 1;  
      if not found_best then --if we haven't found the best yet, use this
        colours[eb_info.guid] = make_colour(BEST_RGB, in_range and NORMAL_ALPHA or OUT_OF_RANGE_ALPHA);
        if in_range then --if it's also in range, we don't need to find the best in range
          break;
        end
        found_best = true;
      elseif in_range then --otherwise we're looking for the next best that's in range
        colours[eb_info.guid] = BEST_LOCAL_COLOUR;
        break;
      end
    end
  end

  for guid,config in pairs(self.configs) do
    local colour = nil;
    if colours[guid] ~= nil then
      colour = colours[guid];
    else
      colour = DEFAULT_COLOUR;
    end

    config.unit_frame.texture:SetColorTexture(colour.r,colour.g,colour.b);
    config.unit_frame:SetAlpha(colour.a);
  end

  self.timer = C_Timer.NewTimer(next_interesting_event, function () Prescience_helper:tick(); end);
end

function Prescience_helper:layout()
  for _,unit_frame in pairs(self.unit_frames) do
    unit_frame:Hide();
  end

  local sorted_for_placement = {}
  for guid,config in pairs(self.configs) do
    tinsert(sorted_for_placement,config);
  end

  table.sort(sorted_for_placement, function (a,b) return a.order < b.order; end);

  local button_count = #sorted_for_placement;
  local column_length = math.ceil(math.sqrt(button_count));
  local row_length = math.ceil(button_count / column_length);

  local first_row_count = button_count - (row_length-1)*column_length

  local row_height = self.db.unit_frames_frame.height / row_length;
  local normal_column_width = self.db.unit_frames_frame.width / column_length;
  local first_row_column_width = self.db.unit_frames_frame.width / first_row_count;

  i = 0;
  for _,config in ipairs(sorted_for_placement) do
    config.unit_frame:ClearAllPoints();
    local width = 0;
    local height = 0;

    if i < first_row_count then
      config.unit_frame:SetPoint(
        "TOPLEFT",
        self.unitFramesParent,
        "TOPLEFT",
        i * first_row_column_width,
        0);

      --substract 1 from width if it isn't the last column to get a faux border
      width = first_row_column_width;
      if i ~= first_row_count-1 then
        width = width - 1; 
      end
      --substract 1 from height if it isn't the last row to get a faux border
      height = row_height;
      if first_row_count ~= button_count then
        height = height - 1;
      end

      config.unit_frame:SetSize(width, height);
    else
      local row = math.floor((i - first_row_count) / column_length + 1);
      local column = i - first_row_count - (row - 1) * column_length;
      if column < 0 then
        print("negative column, i "..i.." row "..row.." column "..column.." first_row_count "..first_row_count.." row_length "..row_length.." column_length "..column_length.." button_count "..button_count);
      end
      config.unit_frame:SetPoint(
        "TOPLEFT",
        self.unitFramesParent,
        "TOPLEFT",
        column * normal_column_width ,
        -row * row_height);

      --substract 1 from width if it isn't last column to get a faux border
      width = normal_column_width;
      if column ~= column_length - 1 then
        width = width - 1;
      end
      --substract 1 from height if it isn't the last row to get a faux border
      height = row_height;
      if row ~= row_length - 1 then
        height = height - 1;
      end

      config.unit_frame:SetSize(width, height);
    end
    if width < config.unit_frame.name:GetUnboundedStringWidth() then
      config.unit_frame.name:Hide();
    else
      config.unit_frame.name:Show();
    end
    config.unit_frame:Show();
    i = i + 1;
  end

  self:tick();
end

function Prescience_helper:on_input(input)

  if InCombatLockdown() then
    print("In combat lockdown, we aren't going to play with a new config");
    return;
  end

  local i = 0;
  local j = 0;

  self.configs = {
  };

  local version_start,version_end,version_string = string.find(input, "^(%d)+?");

  if version_start == nil then
    print("Couldn't find version of input");
    return;
  end

  if version_string ~= CURRENT_VERSION then
    print("Invalid version '"..version_string.."' we expected version '"..CURRENT_VERSION.."'");
    return;
  end

  input = string.sub(input, version_end + 2);

  local to_bytes = un_base85(input);

  --we add 1 here so our bytes_count < on + BYTE_COUNT math works with 1 based indexing
  local bytes_count = #to_bytes + 1;
  local on = 3;
  if bytes_count < on then
    print("Invalid input, not long enough for the header");
    return;
  end;
  local window_size = to_bytes[1]*100;
  local player_count = to_bytes[2];

  if player_count > MAX_RAID_MEMBERS then
    print("We don't support more than MAX_RAID_MEMBERS players");
    return;
  end

  for i=1,player_count do
    if bytes_count < on + 6 then
      print("Invalid input, not long enough for player header");
      return;
    end

    local player_guid = to_player_guid(to_bytes, on);
    on = on + 6;

    local new_player = {
      unit_frame=self.unit_frames[i],
      damages={},
      order=i
    };

    local found_member = self.members[player_guid];
    if found_member ~= nil then
      new_player.slot = found_member.slot;
      new_player.unit_frame.name:SetText(found_member.name);
      new_player.unit_frame:SetAttribute("unit",found_member.slot);
    else
      new_player.unit_frame.name:SetText(player_guid);
    end

    self.configs[player_guid] = new_player;
    
    local prev_window = -1;

    while true do
      if bytes_count < on + 1 then
        print("Invalid input, not long enough for when of player calced damage event in player"..i.." with prev_window: "..prev_window.." and on "..on);
        return;
      end
      local delta_windows = to_bytes[on];
      on = on + 1;
      if delta_windows == 255 then --special value for end of calced damages
        break;
      end
      if bytes_count < on + 5 then
        print("Invalid input, not enough for what of player calced damage event in player"..i.." with prev_window: "..prev_window);
        return;
      end
      prev_window = prev_window + delta_windows + 1; --set prev_window to the current window
      tinsert(new_player.damages,{
        time_at = prev_window * window_size,
        base = to_uint(to_bytes, on,2),
        ebon_mult = 1 + to_bytes[on+2] / 100,
        prescience_mult = 1 + to_bytes[on+3] / 100,
        shifting_sands_mult = 1 + to_bytes[on+4] / 100
      });
      on = on + 5;
    end
  end
  self:layout();
end

function Prescience_helper:GROUP_ROSTER_UPDATE()
  self:update_roster();
end

function Prescience_helper:INSPECT_READY(guid)
  if self.members[guid] == nil then
    return;
  end

  local talentId = GetInspectSpecialization(self.members[guid].slot);

  if talentId == 0 then
    return;
  end

  self.members[guid].spec = talentId;

  local all_ready = true;

  for _,info in pairs(self.members) do
    if info.spec <= 0 then
      all_ready = false;
    end
  end

  if all_ready then
    print("All talent info ready");
  end
end

function Prescience_helper:update_prescience_cooldown()
  local current_charges,_,cd_start,cd_duration = GetSpellCharges(PRESCIENCE_SPELL_ID);

  if current_charges == 0 then
    self.state.prescience.charge1=cd_start+cd_duration;
    self.state.prescience.charge2=cd_start+2*cd_duration;
  elseif current_charges == 1 then
    self.state.prescience.charge1=0;
    self.state.prescience.charge2=cd_start+cd_duration;
  else 
    self.state.prescience.charge1=0;
    self.state.prescience.charge2=0;
  end
end

function Prescience_helper:update_ebon_might_cooldown()
  local start, duration = GetSpellCooldown(EBON_MIGHT_SPELL_ID);
  self.state.ebon_might.ready = start + duration-self.start_time;
end

function Prescience_helper:PLAYER_LOGIN()
  self:update_roster();
  self:update_prescience_cooldown();
  self:update_ebon_might_cooldown();
end

function Prescience_helper:SPELL_UPDATE_COOLDOWN()
  self:update_prescience_cooldown();
  self:update_ebon_might_cooldown();
end

function Prescience_helper:UNIT_AURA(unitTarget, updateInfo)
  if updateInfo == nil then
    return;
  end

  local guid = UnitGUID(unitTarget);
  if guid == nil then
    return;
  end

  local should_tick = false;

  if updateInfo.addedAuras then
    for _,info in ipairs(updateInfo.addedAuras) do
      if info.name == PRESCIENCE_NAME and info.sourceUnit == "player" then
        self.state.prescience.on[guid] = {
          id=info.auraInstanceID,
          expires= info.expirationTime
        };
        if self.in_encounter then
          should_tick = true;
        end
      elseif info.name == EBON_MIGHT_NAME and info.sourceUnit == "player" then
        self.state.ebon_might.on[guid] = {
          id=info.auraInstanceID,
          expires=info.expirationTime
        };
        if self.in_encounter then
          should_tick = true;
        end
      end
    end
  end
  if updateInfo.updatedAuraInstanceIDs then
    for _,id in ipairs(updateInfo.updatedAuraInstanceIDs) do
      local aura_info = C_UnitAuras.GetAuraDataByAuraInstanceID(unitTarget,id);
      if aura_info ~= nil then
        if self.state.prescience.on[guid] and self.state.prescience.on[guid].id == id then
          self.state.prescience.on[guid].expires = aura_info.expirationTime;
          should_tick = true;
        elseif self.state.ebon_might.on[guid] and self.state.ebon_might.on[guid].id == id then
          self.state.ebon_might.on[guid].expires = aura_info.expirationTime;
          should_tick = true;
        end
      end
    end
  end
  if updateInfo.removedAuraInstanceIDs then
    for _,id in ipairs(updateInfo.removedAuraInstanceIDs) do
      if self.state.prescience.on[guid] and self.state.prescience.on[guid].id == id then
        self.state.prescience.on[guid] = nil;
      elseif self.state.ebon_might.on[guid] and self.state.ebon_might.on[guid].id == id then
        self.state.ebon_might.on[guid] = nil;
      end
    end
  end

  if should_tick then
    self:tick();
  end
end

function Prescience_helper:end_fight()
  self.in_encounter = false;
end

function Prescience_helper:ENCOUNTER_END()
  self:end_fight();
end

function Prescience_helper:PLAYER_LEAVING_WORLD()
  self:end_fight();
end

SLASH_PRESCIENCEHELPER1 = '/ph';
function SlashCmdList.PRESCIENCEHELPER(msg, editBox)
  if msg == "show" then
    Prescience_helper.unitFramesParent:Show();
    return;
  end
  if msg == "hide" then
    Prescience_helper.unitFramesParent:Hide();
    return;
  end
  if msg == "debug_start" then
    Prescience_helper:start_fight();
    return;
  end
  if msg == "debug_end" then
    Prescience_helper:end_fight();
    return;
  end
  if msg == "force_roster" then
    Prescience_helper:force_roster();
    return;
  end
  if msg ~= "" then
    print("Unknown command '"..msg.."'");
    return;
  end

  local showing = "2?"..Prescience_helper.player_guid..',';

  local first = true;

  for guid,info in pairs(Prescience_helper.members) do
    if first then
      first = false; 
    else
      showing = showing..',';
    end
    showing = showing..'['..guid..','..info.name..','..info.spec..']';
  end
  
  Prescience_helper.settings_edit_box:SetText(showing)
  Prescience_helper.settings_edit_box:HighlightText()

  Prescience_helper.settings_frame:Show();
end