-- Velocity Macro Sync: the page under Esc > Options > AddOns > Velocity Macro Sync.
-- GotJunk-style canvas: scrolling content, title + intro card, one bordered
-- section "Class Macros: <class>" with a button that opens the macro window
-- and a read-only list of the names in this class's shared set.
local ADDON, NS = ...
local Client = NS.Client

local optionsCategory, optionsFrame
local BOX_W, PAD = 580, 10

local function ClassDisplayName()
	local localized = UnitClass("player")
	return localized or Client.PlayerClass() or "?"
end

local function ClassColor()
	local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[Client.PlayerClass() or ""]
	if c then return c.r, c.g, c.b end
	return 1, 0.82, 0
end

local function OpenMacroWindow()
	if InCombatLockdown() then NS.Warn("cannot open the macro window in combat") return end
	-- Blizzard_MacroUI is load-on-demand.
	if not MacroFrame then
		if C_AddOns and C_AddOns.LoadAddOn then C_AddOns.LoadAddOn("Blizzard_MacroUI")
		elseif LoadAddOn then LoadAddOn("Blizzard_MacroUI") end
	end
	if not MacroFrame then NS.Warn("Blizzard_MacroUI could not be loaded") return end
	-- The Settings window is itself a UI panel; MacroFrame is a "left" UI panel and
	-- is swallowed/hidden while Settings is up. Close Settings first, then show the
	-- macro window on the next frame so the panel manager has settled.
	if SettingsPanel and SettingsPanel:IsShown() then
		HideUIPanel(SettingsPanel)
	elseif InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then
		HideUIPanel(InterfaceOptionsFrame)
	end
	if GameMenuFrame and GameMenuFrame:IsShown() then HideUIPanel(GameMenuFrame) end
	C_Timer.After(0, function()
		if MacroFrame_Show then MacroFrame_Show() else ShowUIPanel(MacroFrame) end
		-- Land on the Character Specific tab (tab 2), which is what we sync.
		local tab2 = MacroFrameTab2 or (MacroFrame.Tabs and MacroFrame.Tabs[2])
		if tab2 and tab2:IsShown() and tab2:IsEnabled() then
			tab2:Click()
		end
	end)
end

local function CreateOptions()
	optionsFrame = CreateFrame("Frame", "VelocityMacroSyncOptions")
	optionsFrame.name = "Velocity Macro Sync"

	local scroll = CreateFrame("ScrollFrame", "VelocityMacroSyncOptionsScroll", optionsFrame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 0, -4)
	scroll:SetPoint("BOTTOMRIGHT", -28, 4)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(620, 600)
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

	-- Top card: name + description.
	local top = Box(content)
	top:SetPoint("TOPLEFT", 16, -16)
	local title = top:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", PAD, -PAD); title:SetText("Velocity Macro Sync")
	local sub = top:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6); sub:SetWidth(BOX_W - 2 * PAD); sub:SetJustifyH("LEFT")
	sub:SetText("Keeps the Character Specific Macros tab identical across every character of the same class. " ..
		"Adds, edits and deletes you make on one character reach the others at their next login; edits are applied " ..
		"in place so macros stay on your action bars. Same-name clashes on first sync are kept as Name~2. " ..
		"Commands: /cms status, sync, list, reset, resetclass.")
	top:SetHeight(PAD + title:GetStringHeight() + 6 + sub:GetStringHeight() + PAD)

	-- Class card.
	local card = Box(content)
	card:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -14)
	local header = card:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", PAD, -PAD)
	local openBtn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
	openBtn:SetSize(160, 22); openBtn:SetText("Open Macro Window")
	openBtn:SetPoint("TOPRIGHT", -PAD, -PAD + 3)
	openBtn:SetScript("OnClick", OpenMacroWindow)
	local summary = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	summary:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6); summary:SetWidth(BOX_W - 2 * PAD); summary:SetJustifyH("LEFT")
	local list = card:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	list:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -8); list:SetWidth(BOX_W - 2 * PAD); list:SetJustifyH("LEFT"); list:SetSpacing(2)

	-- Danger zone: wipe all saved data.
	local danger = Box(content)
	danger:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -14)
	if danger.SetBackdropBorderColor then danger:SetBackdropBorderColor(0.8, 0.25, 0.25, 0.8) end
	local dHeader = danger:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	dHeader:SetPoint("TOPLEFT", PAD, -PAD); dHeader:SetText("|cffff4040Reset|r")
	local dText = danger:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	dText:SetPoint("TOPLEFT", dHeader, "BOTTOMLEFT", 0, -6); dText:SetWidth(BOX_W - 2 * PAD - 180); dText:SetJustifyH("LEFT")
	dText:SetText("Deletes all saved sync data for every class and character on this account. " ..
		"No macros are removed from any character's macro page; each character re-shares what is on its page at its next login.")
	local wipeBtn = CreateFrame("Button", nil, danger, "UIPanelButtonTemplate")
	wipeBtn:SetSize(160, 22); wipeBtn:SetText("Delete All Saved Data")
	wipeBtn:SetPoint("TOPRIGHT", -PAD, -PAD + 3)
	wipeBtn:SetScript("OnClick", function() NS.ConfirmWipe() end)
	danger:SetHeight(PAD + 14 + 6 + math.max(dText:GetStringHeight(), 22) + PAD)

	local function Refresh()
		local classFile = Client.PlayerClass() or "?"
		local r, g, b = ClassColor()
		header:SetFormattedText("Class Macros: |cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, ClassDisplayName())
		local set = (NS.db and NS.db.classes and NS.db.classes[classFile]) or {}
		local names = {}
		for _, e in pairs(set) do names[#names + 1] = e.name end
		table.sort(names, function(a, b) return a:lower() < b:lower() end)
		local _, numChar = Client.GetNumMacros()
		summary:SetFormattedText("%d macro%s in the shared set. This character: %d of %d character slots used.",
			#names, #names == 1 and "" or "s", numChar or 0, Client.MaxCharacterMacros() or 0)
		if #names == 0 then
			list:SetText("|cff888888No class macros stored yet. Create one on the Character Specific tab and it will be synced.|r")
		else
			list:SetText(table.concat(names, "\n"))
		end
		card:SetHeight(PAD + 14 + 6 + summary:GetStringHeight() + 8 + list:GetStringHeight() + PAD)
		local topY, bottom = content:GetTop(), danger:GetBottom()
		if topY and bottom then content:SetHeight(topY - bottom + 24) end
	end

	optionsFrame.Update = Refresh
	optionsFrame:SetScript("OnShow", Refresh)
	NS.OptionsRefresh = function() if optionsFrame:IsShown() then Refresh() end end

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
	if not optionsFrame then CreateOptions() end
end)
