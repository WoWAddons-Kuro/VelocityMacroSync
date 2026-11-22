-- Velocity Macro Sync: the page under Esc > Options > AddOns > Velocity Macro Sync.
-- Four cards on a scrolling canvas: title, Class Macros (two-column table),
-- General Macro Migration (enable + warning + two-group table), Reset.
--
-- Every table row is a small Frame holding FontStrings (and a button), so rows
-- can be variable height and rebuilt on every Refresh. Rows are pooled.
local ADDON, NS = ...
local Client = NS.Client

local optionsCategory, optionsFrame
local BOX_W, PAD = 580, 10
local INNER_W = BOX_W - 2 * PAD

local function ClassDisplayName(classFile)
	if classFile and classFile ~= Client.PlayerClass() then
		local t = LOCALIZED_CLASS_NAMES_MALE
		return (t and t[classFile]) or classFile
	end
	return (UnitClass("player")) or classFile or "?"
end

local function ClassHex(classFile)
	local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile or ""]
	if c then return string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
	return "ffd100"
end

local function OpenMacroWindow()
	if InCombatLockdown() then NS.Warn("cannot open the macro window in combat") return end
	if not MacroFrame then
		if C_AddOns and C_AddOns.LoadAddOn then C_AddOns.LoadAddOn("Blizzard_MacroUI")
		elseif LoadAddOn then LoadAddOn("Blizzard_MacroUI") end
	end
	if not MacroFrame then NS.Warn("Blizzard_MacroUI could not be loaded") return end
	if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel)
	elseif InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then HideUIPanel(InterfaceOptionsFrame) end
	if GameMenuFrame and GameMenuFrame:IsShown() then HideUIPanel(GameMenuFrame) end
	C_Timer.After(0, function()
		if MacroFrame_Show then MacroFrame_Show() else ShowUIPanel(MacroFrame) end
		local tab2 = MacroFrameTab2 or (MacroFrame.Tabs and MacroFrame.Tabs[2])
		if tab2 and tab2:IsShown() and tab2:IsEnabled() then tab2:Click() end
	end)
end

-- ---------------------------------------------------------------------------
-- Confirm-on-enable for auto migration
-- ---------------------------------------------------------------------------
local MIGRATE_WARNING = "WARNING: This will *move* your class-specific macros from General into per-character macros for each class. " ..
	"Make sure you are happy with this addon before you turn this on, because characters referencing general macros " ..
	"will only be updated if this addon is still running when you first login to them."

StaticPopupDialogs["VELOCITYMACROSYNC_ENABLE_MIGRATION"] = {
	text = "Velocity Macro Sync\n\n" .. MIGRATE_WARNING .. "\n\nTurn on automatic migration?",
	button1 = "Enable migration",
	button2 = CANCEL,
	OnAccept = function()
		NS.db.autoMigrate = true
		NS.Print("automatic migration of class-specific General macros is ON. It runs at login for macros on your action bars.")
		if NS.OptionsRefresh then NS.OptionsRefresh() end
	end,
	timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

-- ---------------------------------------------------------------------------
-- Page
-- ---------------------------------------------------------------------------
local function CreateOptions()
	optionsFrame = CreateFrame("Frame", "VelocityMacroSyncOptions")
	optionsFrame.name = "Velocity Macro Sync"

	local scroll = CreateFrame("ScrollFrame", "VelocityMacroSyncOptionsScroll", optionsFrame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 0, -4)
	scroll:SetPoint("BOTTOMRIGHT", -28, 4)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(620, 800)
	scroll:SetScrollChild(content)
	scroll:SetScript("OnSizeChanged", function(self, w) content:SetWidth(math.max(620, w)) end)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local max = self:GetVerticalScrollRange()
		self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 40)))
	end)

	local function Box(parent)
		local box = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
		box:SetWidth(BOX_W)
		if box.SetBackdrop then
			box:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
			box:SetBackdropColor(0, 0, 0, 0.25); box:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.6)
		end
		return box
	end

	-- Row pool: rows are plain frames; Acquire returns a hidden, cleared row.
	local function RowPool(parent)
		local pool = { rows = {}, used = 0, parent = parent }
		function pool:Acquire()
			self.used = self.used + 1
			local r = self.rows[self.used]
			if not r then
				r = CreateFrame("Frame", nil, self.parent)
				r:SetWidth(INNER_W)
				r.c1 = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight"); r.c1:SetJustifyH("LEFT"); r.c1:SetJustifyV("TOP")
				r.c2 = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall"); r.c2:SetJustifyH("LEFT"); r.c2:SetJustifyV("TOP"); r.c2:SetWordWrap(true)
				r.c3 = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall"); r.c3:SetJustifyH("LEFT"); r.c3:SetJustifyV("TOP")
				r.btn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate"); r.btn:SetSize(70, 20); r.btn:SetText("Migrate")
				r.line = r:CreateTexture(nil, "ARTWORK"); r.line:SetColorTexture(0.5, 0.5, 0.5, 0.4); r.line:SetHeight(1)
				self.rows[self.used] = r
			end
			r.c1:SetText(""); r.c2:SetText(""); r.c3:SetText("")
			r.c1:ClearAllPoints(); r.c2:ClearAllPoints(); r.c3:ClearAllPoints(); r.btn:ClearAllPoints(); r.line:ClearAllPoints()
			r.c1:Hide(); r.c2:Hide(); r.c3:Hide(); r.btn:Hide(); r.line:Hide()
			r.btn:SetScript("OnClick", nil); r.btn:SetScript("OnEnter", nil); r.btn:SetScript("OnLeave", nil)
			r:SetScript("OnEnter", nil); r:SetScript("OnLeave", nil); r:EnableMouse(false)
			r:Show()
			return r
		end
		function pool:Reset()
			for i = 1, self.used do self.rows[i]:Hide() end
			self.used = 0
		end
		return pool
	end

	-- ---------------- Top card
	local top = Box(content)
	top:SetPoint("TOPLEFT", 16, -16)
	local ICON = 64
	local logo = top:CreateTexture(nil, "ARTWORK")
	logo:SetSize(ICON, ICON); logo:SetPoint("TOPLEFT", PAD, -PAD)
	logo:SetTexture("Interface\\AddOns\\VelocityMacroSync\\Assets\\VelocityMacroSync_Icon.tga")
	local title = top:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", logo, "TOPRIGHT", PAD, -2); title:SetText("Velocity Macro Sync")
	local sub = top:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6); sub:SetWidth(INNER_W - PAD - ICON); sub:SetJustifyH("LEFT")
	sub:SetText("Keeps the Character Specific Macros tab identical across every character of the same class. " ..
		"Adds and edits you make on one character reach the others at their next login; edits are applied in place so " ..
		"macros stay on your action bars. The addon never deletes a macro. Commands: /velocitymacrosync")
	top:SetHeight(PAD + math.max(ICON, 2 + 16 + 6 + sub:GetStringHeight()) + PAD)

	-- ---------------- Class Macros card
	local card = Box(content)
	card:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -14)
	local header = card:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", PAD, -PAD)
	local openBtn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
	openBtn:SetSize(160, 22); openBtn:SetText("Open Macro Window")
	openBtn:SetPoint("TOPRIGHT", -PAD, -PAD + 3)
	openBtn:SetScript("OnClick", OpenMacroWindow)
	local summary = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	summary:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6); summary:SetWidth(INNER_W); summary:SetJustifyH("LEFT")
	local classRows = RowPool(card)

	-- ---------------- General Macro Migration card
	local mig = Box(content)
	mig:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -14)
	local migHeader = mig:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	migHeader:SetPoint("TOPLEFT", PAD, -PAD); migHeader:SetText("General Macro Migration")
	local cb = CreateFrame("CheckButton", nil, mig, "InterfaceOptionsCheckButtonTemplate")
	cb:SetPoint("TOPLEFT", migHeader, "BOTTOMLEFT", -2, -6)
	cb.Text:SetText("Enable automatic migration of class-specific macros")
	cb:SetScript("OnClick", function(self)
		if self:GetChecked() then
			-- Do NOT set the value here. Revert and ask.
			self:SetChecked(false)
			StaticPopup_Show("VELOCITYMACROSYNC_ENABLE_MIGRATION")
		else
			NS.db.autoMigrate = false
			NS.Print("automatic migration is OFF")
		end
	end)
	local warn = mig:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	warn:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 2, -4); warn:SetWidth(INNER_W); warn:SetJustifyH("LEFT")
	warn:SetText("|cffff4040" .. MIGRATE_WARNING .. "|r")
	local migRows = RowPool(mig)

	-- ---------------- Reset card
	local danger = Box(content)
	danger:SetPoint("TOPLEFT", mig, "BOTTOMLEFT", 0, -14)
	if danger.SetBackdropBorderColor then danger:SetBackdropBorderColor(0.8, 0.25, 0.25, 0.8) end
	local dHeader = danger:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	dHeader:SetPoint("TOPLEFT", PAD, -PAD); dHeader:SetText("|cffff4040Reset|r")
	local dText = danger:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	dText:SetPoint("TOPLEFT", dHeader, "BOTTOMLEFT", 0, -6); dText:SetWidth(INNER_W - 180); dText:SetJustifyH("LEFT")
	dText:SetText("Deletes all saved sync data for every class and character on this account. " ..
		"No macros are removed from any character's macro page; each character re-shares what is on its page at its next login.")
	local wipeBtn = CreateFrame("Button", nil, danger, "UIPanelButtonTemplate")
	wipeBtn:SetSize(160, 22); wipeBtn:SetText("Delete All Saved Data")
	wipeBtn:SetPoint("TOPRIGHT", -PAD, -PAD + 3)
	wipeBtn:SetScript("OnClick", function() NS.ConfirmWipe() end)
	danger:SetHeight(PAD + 14 + 6 + math.max(dText:GetStringHeight(), 22) + PAD)

	-- ---------------- Refresh: rebuild both tables
	local NAME_W, CLASS_W, BTN_W = 150, 150, 70

	local function RefreshClassTable()
		local classFile = Client.PlayerClass() or "?"
		header:SetFormattedText("Class Macros: |cff%s%s|r", ClassHex(classFile), ClassDisplayName(classFile))
		local set = (NS.db and NS.db.classes and NS.db.classes[classFile]) or {}
		local entries = {}
		for _, e in pairs(set) do entries[#entries + 1] = e end
		table.sort(entries, function(a, b) return a.name:lower() < b.name:lower() end)
		local _, numChar = Client.GetNumMacros()
		summary:SetFormattedText("%d macro%s in the shared set. This character: %d of %d character slots used.",
			#entries, #entries == 1 and "" or "s", numChar or 0, Client.MaxCharacterMacros() or 0)

		classRows:Reset()
		local anchor, y = summary, -8
		if #entries == 0 then
			local r = classRows:Acquire()
			r:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y)
			r.c1:SetPoint("TOPLEFT"); r.c1:SetWidth(INNER_W); r.c1:Show()
			r.c1:SetText("|cff888888No class macros stored yet. Create one on the Character Specific tab and it will be synced.|r")
			r:SetHeight(r.c1:GetStringHeight() + 4)
			anchor, y = r, 0
		else
			for _, e in ipairs(entries) do
				local r = classRows:Acquire()
				r:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y)
				r.c1:SetPoint("TOPLEFT", 0, -3); r.c1:SetWidth(NAME_W); r.c1:SetText(e.name); r.c1:Show()
				r.c2:SetPoint("TOPLEFT", NAME_W + 8, -3); r.c2:SetWidth(INNER_W - NAME_W - 8); r.c2:SetText(e.body); r.c2:Show()
				r.line:SetPoint("BOTTOMLEFT", 0, 0); r.line:SetPoint("BOTTOMRIGHT", 0, 0); r.line:Show()
				r:SetHeight(math.max(r.c1:GetStringHeight(), r.c2:GetStringHeight()) + 8)
				anchor, y = r, 0
			end
		end
		card:SetHeight(PAD + 14 + 6 + summary:GetStringHeight() + 8 + (anchor:GetTop() and (summary:GetBottom() - anchor:GetBottom()) or 20) + PAD)
	end

	local function RefreshMigrationTable()
		cb:SetChecked(NS.db and NS.db.autoMigrate and true or false)
		local myClass = Client.PlayerClass()
		local Migrate, Classify = NS.Migrate, NS.Classify
		local mine, others = {}, {}
		if Migrate then
			for _, m in ipairs(Migrate.ReadGeneral()) do
				if not Migrate.IsStub(m.name, m.body) then
					local v = Migrate.VerdictFor(m.body)
					m.verdict = v
					if v.class == myClass then mine[#mine + 1] = m else others[#others + 1] = m end
				end
			end
		end
		local byName = function(a, b) return a.name:lower() < b.name:lower() end
		table.sort(mine, byName); table.sort(others, byName)

		migRows:Reset()
		local anchor, y = warn, -10
		local function AddRow(m)
			local r = migRows:Acquire()
			r:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y)
			r.c1:SetPoint("TOPLEFT", 0, -3); r.c1:SetWidth(NAME_W); r.c1:SetText(m.name); r.c1:Show()
			local v = m.verdict
			local label
			if v.class then label = string.format("|cff%s%s|r", ClassHex(v.class), ClassDisplayName(v.class))
			else label = "|cff888888" .. Classify.Describe(v) .. "|r" end
			r.c3:SetPoint("TOPLEFT", NAME_W + 8, -3); r.c3:SetWidth(INNER_W - NAME_W - 8 - BTN_W - 8); r.c3:SetText(label); r.c3:Show()
			r.btn:SetPoint("TOPRIGHT", 0, -1); r.btn:Show()
			local can = (v.class == myClass)
			r.btn:SetEnabled(can)
			local index = m.index
			r.btn:SetScript("OnClick", function()
				if InCombatLockdown() then NS.Warn("cannot change macros in combat") return end
				local idx = Client.GetMacroIndexByName(m.name)
				if not idx or idx == 0 then idx = index end
				local ok, why = Migrate.One(idx)
				if not ok then NS.Warn("could not migrate \"" .. m.name .. "\": " .. tostring(why)) end
				if NS.OptionsRefresh then NS.OptionsRefresh() end
			end)
			r.btn:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				if can then GameTooltip:SetText("Move this macro into your " .. ClassDisplayName(myClass) .. " macros and convert the General copy to a stub.", 1, 1, 1, 1, true)
				else GameTooltip:SetText(Classify.Describe(v), 1, 1, 1, 1, true) end
				GameTooltip:Show()
			end)
			r.btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
			r.line:SetPoint("BOTTOMLEFT", 0, 0); r.line:SetPoint("BOTTOMRIGHT", 0, 0); r.line:Show()
			r:SetHeight(math.max(r.c1:GetStringHeight(), r.c3:GetStringHeight(), 20) + 6)
			anchor, y = r, 0
		end
		local function Divider(text)
			local r = migRows:Acquire()
			r:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y)
			r.c1:SetPoint("TOPLEFT", 0, -6); r.c1:SetWidth(INNER_W); r.c1:SetText("|cffaaaaaa" .. text .. "|r"); r.c1:Show()
			r:SetHeight(r.c1:GetStringHeight() + 12)
			anchor, y = r, 0
		end
		if #mine == 0 and #others == 0 then
			Divider("No General macros.")
		else
			if #mine > 0 then
				Divider(string.format("Detected as %s (%d)", ClassDisplayName(myClass), #mine))
				for _, m in ipairs(mine) do AddRow(m) end
			end
			if #others > 0 then
				Divider(string.format("Other General macros (%d)", #others))
				for _, m in ipairs(others) do AddRow(m) end
			end
		end
		mig:SetHeight(PAD + 14 + 6 + 26 + 4 + warn:GetStringHeight() + 10 + (warn:GetBottom() and anchor:GetBottom() and (warn:GetBottom() - anchor:GetBottom()) or 20) + PAD)
	end

	local function Refresh()
		if not NS.db then return end
		RefreshClassTable()
		RefreshMigrationTable()
		local topY, bottom = content:GetTop(), danger:GetBottom()
		if topY and bottom then content:SetHeight(topY - bottom + 24) end
	end

	optionsFrame.Update = Refresh
	optionsFrame:SetScript("OnShow", Refresh)
	NS.OptionsRefresh = function() if optionsFrame and optionsFrame:IsShown() then Refresh() end end

	if Settings and Settings.RegisterCanvasLayoutCategory then
		optionsCategory = Settings.RegisterCanvasLayoutCategory(optionsFrame, "Velocity Macro Sync")
		Settings.RegisterAddOnCategory(optionsCategory)
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(optionsFrame)
	end
end

function NS.OpenOptions()
	if not optionsFrame then CreateOptions() end
	if Settings and Settings.OpenToCategory and optionsCategory then
		Settings.OpenToCategory(optionsCategory:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(optionsFrame); InterfaceOptionsFrame_OpenToCategory(optionsFrame)
	end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_LOGIN")
	if not optionsFrame then
		local ok, err = pcall(CreateOptions)
		if not ok then NS.Warn("settings page failed to build: " .. tostring(err)) end
	end
end)
