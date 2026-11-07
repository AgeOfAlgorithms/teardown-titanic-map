#version 2
-- The afloat Titanic map's own script (tools/t2_make.py copies it into mods/titanic). A map carries no gameplay of
-- its own: the game's own sandbox.lua runs beside it (main.xml) and brings what its sandbox maps have - the tools
-- (in multiplayer all of them, unlimited), the Spawn menu, respawns, the players' map markers - and stands down by
-- itself under a game mode. This script adds three things:
--   1. the fog: the game's weather presets fog from 50 m (sunny), and a 270 m ship faded out halfway, so whenever the
--      fog changes (a weather pick) its start and end are pushed out FOG_STRETCH times;
--   2. the host's "Change weather" panel: the game's own list (data/script/weather.lua, hard-coded, no way to add to
--      it) with one more entry, "Dark night". main.xml turns the game's panel off (sandbox.lua param weather=false) and
--      this script's on (param weather=true), so an older main.xml never shows two;
--   3. the ship's whistle: the pull in the wheelhouse (a body tagged whistlepull) sounds the whistles on the forward
--      funnels (locations tagged whistle). The server takes the press and tells every client, and each plays it
--      from the nearest whistle, quieter with distance but heard all over the map.

FOG_STRETCH = 2.5

-- "Dark night": a clear, moonless night (as on 14 April 1912). The game's Night lets the auto-exposure brighten the
-- scene up to 5x (exposure 1 5) and keeps the sky light, so the sky and sea read light grey-blue; here the sky is
-- dimmer, the sky light and the base light are cut, and the exposure may brighten at most 3x, so the ship's lamps
-- (tags night) and the flashlight carry the scene.
-- (first values: sky 0.02, ambient 0.3, fog 0.002, exposure 1 1.5, gamma 0.85 - "too dark"; then sky 0.03, ambient
-- 0.45, fog 0.005, exposure 1 2.2, gamma 0.9 - "could still use a bit more light", the user, 2026-11-07)
DARK = {
	skybox = "night_clear.dds", skyboxbrightness = 0.04, skyboxtint = {0.7, 0.8, 1.0},
	ambient = 0.6, constant = {0.0012, 0.0012, 0.0018}, sunBrightness = 0,
	fogColor = {0.008, 0.01, 0.015}, fogParams = {20, 120, 0.9, 2}, exposure = {1, 3},
	gamma = 0.95, bloom = 1.5,
}

WEATHERS = {
	{"loc@UI_BUTTON_SUNRISE", "sunrise"}, {"loc@UI_BUTTON_SUNNY", "sunny"}, {"loc@UI_BUTTON_FOGGY", "foggy"},
	{"loc@UI_BUTTON_LIGHT_RAIN", "rain"}, {"loc@UI_BUTTON_SUNSET", "sunset"}, {"loc@UI_BUTTON_NIGHT", "night"},
	{"Dark night", "darknight"}, {"loc@UI_BUTTON_RAINY_NIGHT", "rainynight"}, {"loc@UI_BUTTON_SNOWY", "snowy"},
	{"loc@UI_BUTTON_SNOWY_NIGHT", "snowynight"},
}

WHISTLE_COOLDOWN = 8.0       -- s from one blast's start to the next possible one
WHISTLE_BLAST = 4.0          -- s the pull stays down (the blast holds ~4 s, then rings out)
WHISTLE_PULL = 0.12          -- m the handle moves down while it sounds
WHISTLE_VOLUME = 1.0         -- at the whistle
WHISTLE_HALF = 40.0          -- m at which it is at half volume (1 / (1 + d / WHISTLE_HALF))
WHISTLE_MIN = 0.12           -- never quieter than this: heard anywhere on the map
WHISTLE_NEAR = 6.0           -- m: farther away it plays this far from the camera, toward the whistle (our own curve)
SOUND_SPEED = 343.0          -- m/s: far away the blast arrives a little later

-- ------------------------------------------------------------------ server

function server.init()
	fogSet = false                   -- the fog we last wrote (a, b): anything else is a fresh preset to stretch
	pull = FindBody("whistlepull", true)
	pullParts = {}
	if pull ~= 0 then
		SetTag(pull, "interact", "Sound the whistle")
		local shapes = GetBodyShapes(pull)
		for i = 1, #shapes do
			pullParts[i] = {shapes[i], GetShapeLocalTransform(shapes[i])}
		end
	end
	whistleReady = 0
	whistleDown = false              -- the time the pull goes back up (while it is down)
end

local function setPullDown(down)
	for i = 1, #pullParts do
		local s, t = pullParts[i][1], pullParts[i][2]
		local pos = down and VecAdd(t.pos, Vec(0, -WHISTLE_PULL, 0)) or t.pos
		SetShapeLocalTransform(s, Transform(pos, t.rot))
	end
end

-- did player p's interact press mean the pull? (the engine's interact target first; for a small static shape the
-- engine may miss, also a look at the handle from within reach when nothing else is targeted)
local function pulls(p)
	local b = GetPlayerInteractBody(p)
	if b == pull then return true end
	local s = GetPlayerInteractShape(p)
	if s ~= 0 and GetShapeBody(s) == pull then return true end
	if b ~= 0 or s ~= 0 then return false end
	local eye = GetPlayerEyeTransform(p)
	local to = VecSub(GetBodyTransform(pull).pos, eye.pos)
	local d = VecLength(to)
	if d > 1.6 or d < 0.01 then return false end
	return VecDot(VecScale(to, 1 / d), TransformToParentVec(eye, Vec(0, 0, -1))) > 0.9
end

function server.tick(dt)
	local a, b, c, d = GetEnvironmentProperty("fogParams")
	if a and b and not (fogSet and math.abs(a - fogSet[1]) < 0.01 and math.abs(b - fogSet[2]) < 0.01) then
		fogSet = {a * FOG_STRETCH, b * FOG_STRETCH}
		SetEnvironmentProperty("fogParams", fogSet[1], fogSet[2], c, d)
	end

	if pull == 0 then return end
	local now = GetTime()
	if whistleDown and now >= whistleDown then
		setPullDown(false)
		whistleDown = false
	end
	if now < whistleReady then return end
	local players = GetAllPlayers()
	for i = 1, #players do
		local p = players[i]
		if InputPressed("interact", p) and GetPlayerHealth(p) > 0 and pulls(p) then
			whistleReady = now + WHISTLE_COOLDOWN
			whistleDown = now + WHISTLE_BLAST
			setPullDown(true)
			ClientCall(0, "client.whistleBlow")
			break
		end
	end
end

-- the game's setWeather (data/script/weather.lua) for its own presets, plus the dark night
local function applyWeather(env)
	if env ~= "darknight" then
		setWeatherPreset(env)
		return
	end
	SetEnvironmentDefault()
	SetPostProcessingDefault()
	SetEnvironmentProperty("skybox", DARK.skybox)
	SetEnvironmentProperty("skyboxbrightness", DARK.skyboxbrightness)
	SetEnvironmentProperty("skyboxtint", DARK.skyboxtint[1], DARK.skyboxtint[2], DARK.skyboxtint[3])
	SetEnvironmentProperty("ambient", DARK.ambient)
	SetEnvironmentProperty("constant", DARK.constant[1], DARK.constant[2], DARK.constant[3])
	SetEnvironmentProperty("sunBrightness", DARK.sunBrightness)
	SetEnvironmentProperty("sunGlare", 0)
	SetEnvironmentProperty("sunFogScale", 0)
	SetEnvironmentProperty("fogColor", DARK.fogColor[1], DARK.fogColor[2], DARK.fogColor[3])
	SetEnvironmentProperty("fogParams", DARK.fogParams[1], DARK.fogParams[2], DARK.fogParams[3], DARK.fogParams[4])
	SetEnvironmentProperty("exposure", DARK.exposure[1], DARK.exposure[2])
	SetEnvironmentProperty("ambience", "outdoor/night.ogg")
	SetEnvironmentProperty("nightlight", true)
	SetPostProcessingProperty("gamma", DARK.gamma)
	SetPostProcessingProperty("bloom", DARK.bloom)
end

function server.pickWeather(env)
	if not GetBool("level.sandbox") then return end
	for i = 1, #WEATHERS do
		if WEATHERS[i][2] == env then
			applyWeather(env)
			return
		end
	end
end

-- a copy of the game's setWeather (data/script/weather.lua; including that file would also bring its own panel)
function setWeatherPreset(env)
	SetEnvironmentDefault()
	SetPostProcessingDefault()
	if env == "sunset" then
		SetEnvironmentProperty("skybox", "sunset.dds")
		SetEnvironmentProperty("skyboxtint", 1, 0.5, 0.2)
		SetEnvironmentProperty("fogColor", 0.3, 0.2, 0.08)
		SetEnvironmentProperty("fogParams", 80, 200, 1, 6)
		SetEnvironmentProperty("sunBrightness", 1)
		SetEnvironmentProperty("sunColorTint", 0.2, 0.3, 1)
		SetEnvironmentProperty("sunFogScale", 1.0)
		SetEnvironmentProperty("sunGlare", 0.8)
		SetEnvironmentProperty("exposure", 1, 5)
		SetEnvironmentProperty("nightlight", false)
	elseif env == "sunny" then
		SetEnvironmentProperty("skybox", "day.dds")
		SetEnvironmentProperty("skyboxbrightness", 0.7)
		SetEnvironmentProperty("fogColor", 0.9, 0.9, 0.9)
		SetEnvironmentProperty("fogParams", 50, 200, 0.9, 8)
		SetEnvironmentProperty("sunBrightness", 4)
		SetEnvironmentProperty("sunColorTint", 1, 0.8, 0.6)
		SetEnvironmentProperty("exposure", 1, 5)
		SetEnvironmentProperty("sunFogScale", 0.15)
		SetEnvironmentProperty("nightlight", false)
	elseif env == "night" then
		SetEnvironmentProperty("skybox", "cloudy.dds")
		SetEnvironmentProperty("skyboxbrightness", 0.05)
		SetEnvironmentProperty("fogColor", 0.02, 0.02, 0.024)
		SetEnvironmentProperty("fogParams", 20, 120, 0.9, 2)
		SetEnvironmentProperty("exposure", 1, 5)
		SetEnvironmentProperty("ambience", "outdoor/night.ogg")
		SetEnvironmentProperty("nightlight", true)
		SetPostProcessingProperty("gamma", 0.9)
		SetPostProcessingProperty("bloom", 1.5)
	elseif env == "sunrise" then
		SetEnvironmentProperty("skybox", "cloudy.dds")
		SetEnvironmentProperty("skyboxtint", 1, 0.4, 0.2)
		SetEnvironmentProperty("skyboxbrightness", 0.6)
		SetEnvironmentProperty("fogColor", 1, 0.2, 0.1)
		SetEnvironmentProperty("fogParams", 30, 160, 0.95, 6)
		SetEnvironmentProperty("exposure", 1, 5)
		SetEnvironmentProperty("nightlight", true)
	elseif env == "foggy" then
		SetEnvironmentProperty("skybox", "cloudy.dds")
		SetEnvironmentProperty("skyboxtint", 1.0, 0.6, 0.4)
		SetEnvironmentProperty("fogType", "exp2")
		SetEnvironmentProperty("fogColor", 0.48, 0.46, 0.42)
		SetEnvironmentProperty("fogParams", 18.0, 0.3, 1.0, 0.22)
		SetEnvironmentProperty("fogHeightOffset", -31.5)
		SetEnvironmentProperty("exposure", 1, 5)
		SetEnvironmentProperty("wetness", 0.4)
		SetEnvironmentProperty("puddleamount", 0.3)
		SetEnvironmentProperty("nightlight", false)
		SetEnvironmentProperty("slippery", 0.1)
	elseif env == "rain" then
		SetEnvironmentProperty("skybox", "cloudy.dds")
		SetEnvironmentProperty("skyboxtint", 1.0, 0.6, 0.4)
		SetEnvironmentProperty("fogColor", 0.1, 0.1, 0.1)
		SetEnvironmentProperty("fogParams", 0, 70, 0.9, 1)
		SetEnvironmentProperty("exposure", 1, 5)
		SetEnvironmentProperty("wetness", 0.5)
		SetEnvironmentProperty("puddleamount", 0.5)
		SetEnvironmentProperty("puddlesize", 0.7)
		SetEnvironmentProperty("rain", 0.5)
		SetEnvironmentProperty("ambience", "outdoor/rain_light.ogg")
		SetEnvironmentProperty("nightlight", false)
		SetEnvironmentProperty("slippery", 0.2)
	elseif env == "rainynight" then
		SetEnvironmentProperty("skybox", "cloudy.dds")
		SetEnvironmentProperty("skyboxbrightness", 0.02)
		SetEnvironmentProperty("fogColor", 0.02, 0.02, 0.024)
		SetEnvironmentProperty("fogParams", 10, 90, 0.9, 2)
		SetEnvironmentProperty("exposure", 1, 5)
		SetEnvironmentProperty("wetness", 0.7)
		SetEnvironmentProperty("puddleamount", 0.7)
		SetEnvironmentProperty("puddlesize", 0.7)
		SetEnvironmentProperty("rain", 0.9)
		SetEnvironmentProperty("ambience", "outdoor/rain_heavy.ogg")
		SetEnvironmentProperty("nightlight", true)
		SetEnvironmentProperty("slippery", 0.3)
		SetPostProcessingProperty("gamma", 0.9)
		SetPostProcessingProperty("bloom", 1.5)
	elseif env == "snowy" then
		SetEnvironmentProperty("skybox", "cool_day.dds")
		SetEnvironmentProperty("skyboxtint", 0.7, 0.7, 1.0)
		SetEnvironmentProperty("skyboxbrightness", 0.4)
		SetEnvironmentProperty("ambient", 1.0)
		SetEnvironmentProperty("fogColor", 0.35, 0.45, 0.6)
		SetEnvironmentProperty("fogParams", 10, 200, 1.0, 1.5)
		SetEnvironmentProperty("ambience", "outdoor/winter.ogg")
		SetEnvironmentProperty("sunbrightness", 3.14)
		SetEnvironmentProperty("suncolortint", 1, 0.85, 0.75)
		SetEnvironmentProperty("sunfogscale", 0.25)
		SetEnvironmentProperty("sunglare", 0.35)
		SetEnvironmentProperty("nightlight", false)
		SetEnvironmentProperty("slippery", 0.3)
		SetEnvironmentProperty("snowamount", 0.2)
		SetEnvironmentProperty("snowdir", 0.2, -1, 0.2, 0.2)
		SetPostProcessingProperty("saturation", 0.7)
		SetPostProcessingProperty("colorbalance", 0.7, 0.8, 1.0)
	elseif env == "snowynight" then
		SetEnvironmentProperty("skybox", "cold_wispy_sky.dds")
		SetEnvironmentProperty("skyboxbrightness", 0.035)
		SetEnvironmentProperty("fogColor", 0.005, 0.0055, 0.006)
		SetEnvironmentProperty("fogParams", 1, 125, 0.9, 0.5)
		SetEnvironmentProperty("constant", 0.002, 0.002, 0.002)
		SetEnvironmentProperty("ambient", 1.0)
		SetEnvironmentProperty("fogscale", 1.5)
		SetEnvironmentProperty("ambience", "outdoor/winter.ogg")
		SetEnvironmentProperty("nightlight", true)
		SetEnvironmentProperty("slippery", 0.3)
		SetEnvironmentProperty("snowamount", 0.2)
		SetEnvironmentProperty("snowdir", 0.2, -1, 0.2, 0.2)
		SetPostProcessingProperty("saturation", 0.7)
		SetPostProcessingProperty("colorbalance", 0.7, 0.8, 1.0)
		SetPostProcessingProperty("gamma", 0.85)
		SetPostProcessingProperty("bloom", 1.5)
	end
end

-- ------------------------------------------------------------------ client

function client.init()
	weatherPanel = GetBoolParam("weather", false)    -- (main.xml: on, with the game's own panel off)
	weatherAlpha = 0
	weatherActive = false
	whistleSnd = LoadSound("MOD/snd/whistle.ogg")
	whistleAt = {}
	local locs = FindLocations("whistle", true)
	for i = 1, #locs do
		whistleAt[#whistleAt + 1] = GetLocationTransform(locs[i]).pos
	end
	whistleQueued = false            -- the time the blast reaches this camera
end

-- the nearest whistle to point c -> position, distance
local function nearestWhistle(c)
	local best, bd = nil, 1e9
	for i = 1, #whistleAt do
		local d = VecLength(VecSub(whistleAt[i], c))
		if d < bd then best, bd = whistleAt[i], d end
	end
	return best, bd
end

function client.whistleBlow()
	local w, d = nearestWhistle(GetCameraTransform().pos)
	if w then whistleQueued = GetTime() + d / SOUND_SPEED end
end

local function playWhistle()
	local c = GetCameraTransform().pos
	local w, d = nearestWhistle(c)
	if not w then return end
	local vol = WHISTLE_VOLUME * math.max(WHISTLE_MIN, 1 / (1 + d / WHISTLE_HALF))
	local at = w
	if d > WHISTLE_NEAR then      -- (the engine's own fall-off would silence it far off: play it near, toward it)
		at = VecAdd(c, VecScale(VecSub(w, c), WHISTLE_NEAR / d))
	end
	PlaySound(whistleSnd, at, vol, false)
end

function client.tick(dt)
	if whistleQueued and GetTime() >= whistleQueued then
		whistleQueued = false
		playWhistle()
	end

	if not (weatherPanel and GetBool("level.sandbox") and IsPlayerHost()) then
		weatherActive = false
		return
	end
	-- the game's tickWeather (data/script/weather.lua)
	if PauseMenuButton("loc@CHANGE_WEATHER") then
		weatherActive = true
		SetBool("game.ui.hidemods", true)
	end
	if weatherActive and weatherAlpha == 0.0 then
		SetValue("weatherAlpha", 1.0, "easeout", 0.3)
	end
	if not weatherActive and weatherAlpha == 1.0 then
		SetValue("weatherAlpha", 0.0, "easein", 0.3)
		SetBool("game.ui.hidemods", false)
	end
	SetBool("game.windows.weather.active", weatherActive)
end

-- the game's drawWeather with the dark night in the list (and a plain Close button for every input device)
function client.draw()
	if not (weatherPanel and GetBool("level.sandbox") and IsPlayerHost()) or weatherAlpha <= 0.0 then return end
	if LastInputDevice() == 2 then             -- (gamepad: UI_DEVICE_GAMEPAD lives in the game's ui_helpers.lua)
		UiSetCursorState(2)                    -- (hide and lock)
	end
	if weatherActive then
		UiMakeInteractive()
		SetBool("game.disablepause", true)
	end
	local width, padding, bh, sep = 380, 40, 38, 20
	local height = 60 + (#WEATHERS + 1) * (bh + sep) + 10
	UiPush()
	UiTranslate(-230 + 270 * weatherAlpha, UiMiddle())
	UiAlign("left middle")
	UiColor(0, 0, 0, 0.75 * weatherAlpha)
	UiImageBox("ui/common/box-solid-10.png", width, height, 10, 10)
	UiWindow(width, height)
	UiAlign("top left")
	if InputPressed("menu_cancel") or InputPressed("pause") or
		(GetBool("game.cursor.enabled") and not UiIsMouseInRect(UiWidth(), UiHeight()) and InputPressed("lmb")) then
		weatherActive = false
	end
	UiAlign("center middle")
	UiTranslate(UiWidth() / 2, 60)
	UiFont("regular.ttf", 27)
	local bw = width - 2 * padding
	UiColor(0.96, 0.96, 0.96)
	UiButtonImageBox("ui/common/box-outline-fill-6.png", 6, 6, 0.96, 0.96, 0.96, 0.8)
	UiButtonHoverColor(1.0, 1.0, 0.5, 1)
	local picked = nil
	for i = 1, #WEATHERS do
		if UiTextButton(WEATHERS[i][1], bw, bh) then picked = WEATHERS[i][2] end
		UiTranslate(0, bh + sep)
	end
	UiTranslate(0, 10)
	if UiTextButton("loc@UI_BUTTON_CLOSE", bw, bh) then
		weatherActive = false
	end
	UiPop()
	if picked then
		ServerCall("server.pickWeather", picked)
	end
end
