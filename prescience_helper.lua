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

local GCD_BASE = 1.5;

local PRESCIENCE_DURATION = 18;

local INTERWOVEN_THREADS_ID = 412713;
local PRESCIENCE_SPELL_ID = 409311;
local PRESCIENCE_NAME = "Prescience";
local EBON_MIGHT_SPELL_ID = 395152;
local EBON_MIGHT_NAME = "Ebon Might";

local DEFAULT_EBON_MIGHT_DURATION = 21.6;

Prescience_helper = CreateFrame("Frame")

local function copy_table(from, into)
  for k,v in pairs(from) do
    if into[k] == nil then
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

function Prescience_helper:ADDON_LOADED(addon_name)
  if addon_name == "Prescience_helper" then
    prescience_helper_db = prescience_helper_db or {}
    self.db = prescience_helper_db;
    copy_table(db_defaults, self.db);

    self.members = {};
    self.configs = {};
    self.state = make_clean_state();
    self.start_time = 0;
    self.in_encounter = false;
    self.player_guid = UnitGUID("player");

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
    end);

    self.ready_unit_frames = {};

    self.timer = C_Timer.NewTicker(0.25,function() Prescience_helper:tick(); end);
  end
end

function Prescience_helper:get_unit_frame()
  local ready_unit_frames_count = #self.ready_unit_frames;
  if ready_unit_frames_count == 0 then
    local new_button = CreateFrame("Button", nil,nil, "SecureUnitButtonTemplate");
    new_button.texture = new_button:CreateTexture();
    new_button.texture:SetAllPoints(new_button);
    new_button:SetAttribute("type","target");
    new_button:Hide();
    return new_button;
  else
    local popped = self.ready_unit_frames[ready_unit_frames_count];
    self.ready_unit_frames[ready_unit_frames_count] = nil;
    return popped;
  end
end

function Prescience_helper:return_unit_frame(frame)
  frame:Hide();
  table.insert(self.ready_unit_frames, frame);
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

function Prescience_helper:force_update_roster()
  self.members = {};
  self:update_roster();
end

function Prescience_helper:fake_roster()
  self.members = {};

  for guid,info in pairs(self.configs) do
    self.members[guid] = {
      slot = "player",
      spec = -1,
      config = info
    };
  end

  self:layout();
end

function Prescience_helper:update_roster()
  for guid,info in pairs(self.members) do
    info.prevSlot = info.slot;
    info.slot = nil;
  end

  for i = 1,40 do
    local checking = "raid"..i;

    if UnitExists(checking) then
      local guid = UnitGUID(checking);
      if guid ~= self.player_guid then
        if self.members[guid] == nil then
          self.members[guid] = {
            slot = checking,
            spec = -1,
            avg = 0,
            amounts = {}
          };
        else
          self.members[guid].slot = checking;
          if self.members[guid].prevSlot ~= checking then
            --our slot has changed, button needs to change, but we can't do this in combat? Just brick the UI I guess
            if self.members[guid].button then
              self.members[guid].button:SetAttribute("unit", checking);
            end
          end
        end
      end
    end
  end

  local removed = {};

  for guid,info in pairs(self.members) do
    if info.slot == nil then
      if info.button ~= nil then
        self:return_unit_frame(info.button);
        info.button = nil;
      end
      removed[guid] = true;
    end
  end

  for guid,_ in pairs(removed) do
    self.members[guid] = nil;
  end
  self:layout();
end

local function get_dmg_value(config,time)
  if config.amounts_length <= time then
    return config.average;
  else
    return config.amounts[time];
  end
end

local function get_info_for_eb_cast(members,time,duration)
  local values = {};

  for guid,info in pairs(members) do
    if info.config ~= nil then
      local start_floor = math.floor(time);
      local start_ceil = math.ceil(time);
      local start_portion = start_ceil - time;

      local end_floor = math.floor(time+duration);
      local end_portion = time+duration-end_floor;

      local adding = {
        guid=guid,
        info=info,
        value=0
      };

      adding.value = get_dmg_value(info.config, start_floor) * start_portion;
      adding.value = adding.value + get_dmg_value(info.config, end_floor) * end_portion;

      for i=start_ceil,end_floor do
        adding.value = adding.value + get_dmg_value(info.config,i);
      end

      table.insert(values,adding);
    end
  end

  table.sort(values,function(a,b) return a.value > b.value; end);

  return values;
end

local IGNORE_COLOUR = {r=0.3,g=0.3,b=0.3,a=1};
local DEAD_COLOUR = {r=0,g=0,b=0,a=1};
local BEST_COLOUR = {r=0,g=1,b=0,a=1};
local BEST_LOCAL_COLOUR = {r=1,g=1,b=0};

local function do_next_cast(time, state, members)
  local haste = GetHaste() + 1;
  local gcd = 1.5 / haste;
  local eb_cast_time = 1.5 / haste;

  local _,current_gcd = GetSpellCooldown(61304);

  local p1 = state.prescience.charge1;
  local p2 = state.prescience.charge2;
  local next_eb_cast = state.ebon_might.ready;

  if next_eb_cast < time+current_gcd then
    next_eb_cast = time+current_gcd;
  end
  if p2 < time+current_gcd then
    p2 = time+current_gcd;
  end
  if p1 < time+current_gcd then
    p1 = time+current_gcd;
  end

  local eb_cast = get_info_for_eb_cast(members, next_eb_cast + eb_cast_time, DEFAULT_EBON_MIGHT_DURATION);

  local returning = {};

  for _,eb_info in ipairs(eb_cast) do
    if eb_info.info.button then
      eb_info.is_dead = UnitIsDead(eb_info.info.slot);
      if eb_info.is_dead then
        eb_info.colour = DEAD_COLOUR;
      else
        eb_info.colour = IGNORE_COLOUR;
      end
      local in_range_res = IsSpellInRange(PRESCIENCE_NAME, eb_info.info.slot);
      eb_info.in_range = in_range_res ~= nil and in_range_res ~= 0;
      table.insert(returning, eb_info);
    end
  end


  --eb_cast is returned from get_info_for_eb_cast sorted largest to smallest, so we go through them
  local found_best = false;
  for _,eb_info in ipairs(returning) do
    local doesnt_have_prescience_for_next_em = state.prescience.on[eb_info.guid] == nil or state.prescience.on[eb_info.guid].expires < next_eb_cast + eb_cast_time
    if not eb_info.is_dead and doesnt_have_prescience_for_next_em  then --if we're not dead and we don't have prescience that'll last until the next ebon might
      if not found_best then --if we haven't found the best yet, use this
        eb_info.colour = BEST_COLOUR;
        if eb_info.in_range then --if it's also in range, we don't need to find the best in range
          return returning;
        end
        found_best = true;
      elseif eb_info.in_range then --otherwise we're looking for the next best that's in range
        eb_info.colour = BEST_LOCAL_COLOUR;
        return returning;
      end
    end
  end

  return returning;
end

function Prescience_helper:tick()
  local time = 0;
  if self.in_encounter then
    time = GetTime() - self.start_time;
  end
  local res = do_next_cast(time, self.state, self.members);

  for _,info in ipairs(res) do
    local alpha = 1;
    if not info.in_range then
      alpha = 0.5;
    end
    info.info.button.texture:SetColorTexture(info.colour.r,info.colour.g,info.colour.b, alpha);
  end
end

function Prescience_helper:layout()
  for _,member in pairs(self.members) do
    if member.button ~= nil then
      self:return_unit_frame(member.button);
      member.button = nil;
    end
  end

  local sorted_for_placement = {}
  for guid,info in pairs(self.members) do
    info.config = self.configs[guid]; --if self.configs[guid] doesn't exist, it'll set it to nil for free      
    if info.config ~= nil then
      local button = self:get_unit_frame();
      button:SetAttribute("unit",self.members[guid].slot);
      info.button = button;
      table.insert(sorted_for_placement, info);
    end
  end

  table.sort(sorted_for_placement, function (a,b) return a.config.order < b.config.order; end);

  local button_count = #sorted_for_placement;
  local column_length = math.ceil(math.sqrt(button_count));
  local row_length = math.ceil(button_count / column_length);

  local first_row_count = button_count - (row_length-1)*column_length

  local row_height = self.db.unit_frames_frame.height / row_length;
  local normal_column_width = self.db.unit_frames_frame.width / column_length;
  local first_row_column_width = self.db.unit_frames_frame.width / first_row_count;

  i = 0;
  for _,info in ipairs(sorted_for_placement) do
    info.button:ClearAllPoints();
    if i < first_row_count then
      info.button:SetPoint(
        "TOPLEFT",
        self.unitFramesParent,
        "TOPLEFT",
        i * first_row_column_width,
        0);
        info.button:SetSize(first_row_column_width, row_height);
    else
      local row = math.floor((i - first_row_count) / column_length + 1);
      local column = i - first_row_count - (row - 1) * column_length;
      if column < 0 then
        print("negative column, i "..i.." row "..row.." column "..column.." first_row_count "..first_row_count.." row_length "..row_length.." column_length "..column_length.." button_count "..button_count);
      end
      info.button:SetPoint(
        "TOPLEFT",
        self.unitFramesParent,
        "TOPLEFT",
        column * normal_column_width ,
        -row * row_height);
      info.button:SetSize(normal_column_width, row_height);
    end
    info.button:Show();
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

  local version = tonumber(version_string);

  if math.floor(version) ~= version then
    print("Invalid version: '"..version_string.."'");
    return;
  end

  input = string.sub(input, version_end + 2);

  for member in string.gmatch(input,"([^>]+)>") do
    local guid,average,amounts = string.match(member,"([^<]+)<([^<]+)<(.*)");

    self.configs[guid] = {
      guid=guid,
      average=average,
      amounts={},
      order=i
    };
    
    j = 0;
    for amount in string.gmatch(amounts,"([^,]+),") do
      self.configs[guid].amounts[j] = tonumber(amount);
      j = j + 1;
    end
    self.configs[guid].amounts_length = j;
    i = i + 1;
  end

  if i < 2 then
    return;
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
    self.state.prescience.charge1=cd_start+cd_duration-self.start_time;
    self.state.prescience.charge2=cd_start+2*cd_duration-self.start_time;
  elseif current_charges == 1 then
    self.state.prescience.charge1=0;
    self.state.prescience.charge2=cd_start+cd_duration-self.start_time;
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

function Prescience_helper:SPELL_UPDATE_COOLDOWN(unit, castGuid, spellId)
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

  if updateInfo.addedAuras then
    for _,info in ipairs(updateInfo.addedAuras) do
      if info.name == PRESCIENCE_NAME and info.sourceUnit == "player" then
        self.state.prescience.on[guid] = {
          id=info.auraInstanceID,
          expires= info.expirationTime
        };
        if self.in_encounter then
          self:tick();
        end
      elseif info.name == EBON_MIGHT_NAME and info.sourceUnit == "player" then
        self.state.ebon_might.on[guid] = {
          id=info.auraInstanceID,
          expires=info.expirationTime
        };
        if self.in_encounter then
          self:tick();
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
        elseif self.state.ebon_might.on[guid] and self.state.ebon_might.on[guid].id == id then
          self.state.ebon_might.on[guid].expires = aura_info.expirationTime;
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
end

function get_best_target_for_times(start, last, count, members)
  local returning = {};

  for i=1,count do
    returning[i] = {
      val=0
    };
  end

  start = floor(start);
  last = ceil(last);

  for name,data in pairs(members) do
    local total = 0;
    for i=start,last do
      if data.by_time[i] == nil then
        total = total + data.avg * (last - i);
        break;
      else
        total = total + data.by_time[i];
      end
    end

    for i = 1,count do
      if total > returning[i].val then
        for k = count - 1, i, -1 do
          returning[k+1] = returning[k];
        end
        returning[i] = {
          name = name,
          val = total
        };
        break;
      end
    end
  end

  return returning;
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

local ph_show_settings_frame = CreateFrame("Frame", "PrescienceHelperFrame", Prescience_helper, "DialogBoxFrame");
ph_show_settings_frame:ClearAllPoints();
ph_show_settings_frame:SetPoint(
  "CENTER",
  nil,
  "CENTER",
  0,
  0)
ph_show_settings_frame:SetSize(750, 400)
ph_show_settings_frame:SetBackdrop({
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\PVPFrame\\UI-Character-PVP-Highlight",
  edgeSize = 16,
  insets = { left = 8, right = 8, top = 8, bottom = 8 }});
ph_show_settings_frame:SetMovable(true);
ph_show_settings_frame:SetClampedToScreen(true);

local ph_scroll_frame = CreateFrame("ScrollFrame", "PrescienceHelperScrollFrame", ph_show_settings_frame, "UIPanelScrollFrameTemplate")
ph_scroll_frame:SetPoint("LEFT", 16, 0)
ph_scroll_frame:SetPoint("RIGHT", -32, 0)
ph_scroll_frame:SetPoint("TOP", 0, -32)
--ph_scroll_frame:SetPoint("BOTTOM", PrescienceHelperScrollFrameButton, "TOP", 0, 0)

local ph_edit_box = CreateFrame("EditBox", "PrescienceHelperEditBox", ph_scroll_frame)
ph_edit_box:SetSize(ph_scroll_frame:GetSize())
ph_edit_box:SetMultiLine(true)
ph_edit_box:SetAutoFocus(true)
ph_edit_box:SetFontObject("ChatFontNormal")
ph_edit_box:SetScript("OnEscapePressed", function() ph_show_settings_frame:Hide() end)
ph_scroll_frame:SetScrollChild(ph_edit_box)

ph_show_settings_frame:SetResizable(true)
ph_show_settings_frame:SetResizeBounds(150, 100, nil, nil)

local ph_resize_button = CreateFrame("Button", "PrescienceHelperResizeButton", ph_show_settings_frame)
ph_resize_button:SetPoint("BOTTOMRIGHT", -6, 7)
ph_resize_button:SetSize(16, 16)

ph_resize_button:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
ph_resize_button:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
ph_resize_button:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

ph_resize_button:SetScript("OnMouseDown", function(self, button)
  if button == "LeftButton" then
    ph_show_settings_frame:StartSizing("BOTTOMRIGHT")
    self:GetHighlightTexture():Hide()
  end
end)
ph_resize_button:SetScript("OnMouseUp", function(self, _)
    ph_show_settings_frame:StopMovingOrSizing()
    self:GetHighlightTexture():Show()
    ph_edit_box:SetWidth(ph_scroll_frame:GetWidth())
end)

ph_show_settings_frame:SetScript("OnHide", function() Prescience_helper:on_input(ph_edit_box:GetText()); end);

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
  if msg == "fake_roster" then
    Prescience_helper:fake_roster();
    return;
  end
  if msg ~= "" then
    print("Unknown command '"..msg.."'");
    return;
  end

  local showing = "";

  local first = true;

  for guid,info in pairs(Prescience_helper.members) do
    if first then
      first = false; 
    else
      showing = showing..',';
    end
    showing = showing..'['..guid..','..info.spec..']';
  end
  
  ph_edit_box:SetText(showing)
  ph_edit_box:HighlightText()

  ph_show_settings_frame:Show();
end