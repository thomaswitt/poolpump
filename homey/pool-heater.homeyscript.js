/**
 * Pool Heater controller. Single source of truth for pool-heating behaviour.
 *
 * Intent model:
 *   The virtual device's Power switch (boolean1) is a SOFT INTENT - "heat
 *   when economical, off otherwise". Not a direct on/off to the pump.
 *   The pump's actual on/off is decided here based on outside-air temp,
 *   time of day, pool-vs-target gap, and an optional Boost override.
 *
 * Cadence:
 *   Triggered by an Advanced Flow on a 5-minute cron (no script timer -
 *   keeps the flow visible to the operator). Also re-runnable on demand
 *   from device-toggle triggers.
 *
 * Strategy:
 *   - Heat only when ambient >= 22C AND time in 09:00..15:00 local. On warm
 *     mornings (ambient >= 24C) the window opens early, from 07:00.
 *   - Mode: silent by default (highest COP, lowest draw). Smart-upgrade
 *     on a wide gap is gated by SMART_GAP_C — set to 0 to disable
 *     entirely (the energy-saving default). Boost is the user override
 *     for faster, more-expensive heating.
 *   - Stop when pool >= target + hysteresis; resume only once pool has
 *     fallen to <= target - hysteresis (real deadband — avoids on/off thrash).
 *   - Hard floor: ambient < 18C never heats, even if intent ON or Boost ON.
 */
"use strict";

// --- configuration --------------------------------------------------------

const POOLPUMP_HOST = "http://192.168.3.2:8090";
const PUMP_HTTP_TIMEOUT_MS = 4000;

// Devices (looked up by name to survive ID changes; trim-aware to match
// the leading-space quirk on `' Netatmo Terrasse'`).
const VDEVICE_NAME = "Pool Heater";
const NETATMO_OUTDOOR_NAME = " Netatmo Terrasse";

// Local timezone for time-of-day decisions and the `Last Updated` text.
// HomeyScript runs on Athom Cloud where Date defaults to UTC; without an
// explicit zone, our heating window (9-15 local) would be evaluated in
// UTC = 6-12 (summer, UTC+3), which is wrong.
const TIMEZONE = "Europe/Nicosia";

// Strategy thresholds (see project_pool_heat_strategy.md).
const AMBIENT_HARD_FLOOR_C = 18; // below this: never heat
const AMBIENT_SOFT_FLOOR_C = 22; // below this in window: only with explicit boost
const HEATING_WINDOW_START_H = 9; // local time
const HEATING_WINDOW_END_H = 15;
// Warm-morning early start: when ambient is already >= EARLY_START_AMBIENT_C,
// open the heating window as early as EARLY_START_HOUR_H instead of 09:00. The
// pump's COP is set by air temp, not the clock (manual: operates -15..43°C), so
// a warm post-sunrise morning heats efficiently; the 09:00 default only guards
// nighttime heat-retention, not COP.
const EARLY_START_HOUR_H = 7; // earliest start when warm enough
const EARLY_START_AMBIENT_C = 24; // ambient at/above which the window opens early
const TARGET_HYSTERESIS_C = 0.5; // stop heating when pool >= target + this; resume when <= target - this
// Smart-mode upgrade threshold: if (target - pool) > SMART_GAP_C, upgrade
// silent → smart for faster heat at higher consumption.
//   0  = DISABLED — always run silent (energy-saving default).
//   2  = old behavior — upgrade when pool is >2°C below target.
// Boost is independent of this knob.
const SMART_GAP_C = 0;

// Pool-temperature source — set per-installation:
//   true  — the virtual device's `measure_temperature` is bound (via Homey
//           "Reflect") to a dedicated water sensor (e.g. a Zigbee pool
//           thermometer). Use that value for heating decisions and DO NOT
//           overwrite it; Reflect would either fight the write or revert
//           it. Falls back to pump inlet/outlet only if the virtual
//           device has no value at all.
//   false — no dedicated sensor. Use the pump's TEMP_INLET (block 1000 /
//           addr 1001, 0.1°C precision) as the pool-temperature input,
//           and overwrite the virtual device's `measure_temperature` with
//           it every tick.
const EXTERNAL_POOL_TEMP_SENSOR = true;

// Capability field IDs on the existing DeviceCapabilities-app virtual device.
// Discovered by inspecting `Homey.devices.getDevices()` state:
//   number3 Ambient, number4 Compressor, number5 Outlet,
//   number6 Power Consumption (Show-As measure_power → Insights "Power Usage")
//   text1 Last Updated, text2 OperatingStatus, text3 Current Errors,
//   boolean1/2 Power/Boost intents,
//   boolean3 Pump Running (plain boolean, Insights graphs on/off bands),
//   boolean4 Pump Error (Show-As alarm_pump_device → standard pump-alarm UI).
//
// Pool temperature is surfaced via the DC custom field `number1`
// ("Temperature (Measured)", Show-As measure_temperature) — written through
// the `virtualdevice_set_number` flow card (NOT direct `setCapabilityValue`,
// which returns "Capability Not Setable"). Exception: with
// EXTERNAL_POOL_TEMP_SENSOR=true, number1 is Reflect-bound to a dedicated
// sensor and we never write it (see the pool_temp guard further below).
//
// Number slot history:
//   number1 was "Temperature (Measured)" (Show-As measure_temperature). With
//     EXTERNAL_POOL_TEMP_SENSOR=true the field is now Reflect-bound to the
//     dedicated Zigbee thermometer and we never write it.
//   number6 was "Target Temperature Set" (duplicate of target_temperature);
//     slot was reused for Power Consumption after that field was deleted.
const VFIELD = {
  power_intent: { id: "boolean1", name: "Power" },
  boost_intent: { id: "boolean2", name: "Boost Mode" },
  pump_running: { id: "boolean3", name: "Pump Running" },
  pump_error: { id: "boolean4", name: "Pump Error" },
  // pool_temp → number1 (Show-As measure_temperature). Only written when
  // EXTERNAL_POOL_TEMP_SENSOR=false; with the external sensor on, number1 is
  // Reflect-bound and left untouched. Entry must exist either way so the
  // pump-sensor fallback path (below) doesn't throw `unknown vfield`.
  pool_temp: { id: "number1", name: "Temperature (Measured)" },
  ambient: { id: "number3", name: "Ambient Temperature" },
  compressor: { id: "number4", name: "Compressor Rate" },
  outlet: { id: "number5", name: "Outlet Temperature" },
  power_w: { id: "number6", name: "Power Consumption" },
  last_updated: { id: "text1", name: "Last Updated" },
  operating_status: { id: "text2", name: "OperatingStatus" },
  current_errors: { id: "text3", name: "Current Errors" },
  // mode list (list1) removed from device — pool only ever heats,
  // so cool/auto/heat selector was noise. Pump-side STATUS_MODE should stay
  // pinned to 'heat'; we don't set it from this script (no `model heat`
  // command verb in poolpump server yet — TODO if it ever drifts).
};

// --- helpers --------------------------------------------------------------

const round1 = (n) => Math.round(n * 10) / 10;

const findDevice = (devices, name) => {
  const wanted = name.trim().toLowerCase();
  const matches = Object.values(devices).filter(
    (d) => d.name && d.name.trim().toLowerCase() === wanted,
  );
  if (matches.length === 0) throw new Error(`Device not found: "${name}"`);
  if (matches.length > 1)
    throw new Error(`Multiple devices named "${name}" - need disambiguation`);
  return matches[0];
};

const readNumber = (device, capabilityId) => {
  const v = device.capabilitiesObj?.[capabilityId]?.value;
  if (typeof v !== "number")
    throw new Error(`"${device.name}" missing capability "${capabilityId}"`);
  return v;
};

// HomeyScript ships node-fetch v2.6.7 (per athombv.github.io/com.athom.homeyscript/).
// node-fetch v2 supports a built-in `timeout` option that throws FetchError
// after N ms - simpler and more portable than the AbortController dance.
// We don't rely on global AbortController/setTimeout being polyfilled.
//
// Pump HTTP API:
//   GET  /        -> 14-field JSON snapshot, or 500 if no telemetry yet.
//   POST /        -> body 'on'|'off'|'mode-silent'|'mode-auto'|'mode-boost'|'settemp NN'
const pumpStatus = async () => {
  const res = await fetch(POOLPUMP_HOST + "/", {
    timeout: PUMP_HTTP_TIMEOUT_MS,
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`pump GET / -> HTTP ${res.status}: ${text.slice(0, 200)}`);
  }
  return res.json();
};

const pumpCommand = async (verb) => {
  const res = await fetch(POOLPUMP_HOST + "/", {
    method: "POST",
    headers: { "content-type": "text/plain" },
    body: verb,
    timeout: PUMP_HTTP_TIMEOUT_MS,
  });
  const body = await res.text().catch(() => "");
  if (!res.ok)
    throw new Error(
      `pump POST '${verb}' -> HTTP ${res.status}: ${body.slice(0, 200)}`,
    );
  return body;
};

// Wrapper around the DeviceCapabilities app's flow cards. Mirrors the
// existing 'Pool Heater' flow's pattern so the runtime contract is
// identical - we just call them from script instead of from drag-drop.
const setVField = async (vDevice, fieldKey, value) => {
  const field = VFIELD[fieldKey];
  if (!field) throw new Error(`unknown vfield "${fieldKey}"`);

  const isBool = typeof value === "boolean";
  const isNum = typeof value === "number";
  const isStr = typeof value === "string";
  const isList = !isBool && !isNum && !isStr; // list values are { id, name } objects

  const cardSuffix = isBool
    ? "virtualdevice_set_boolean"
    : isNum
      ? "virtualdevice_set_number"
      : isList
        ? "virtualdevice_set_list"
        : "virtualdevice_set_text";

  const args = { field };
  if (isBool) args.boolean = value;
  if (isNum) {
    args.number = value;
    args.mode = "nothing";
  }
  if (isStr) args.text = value;
  if (isList) {
    args.value = value;
    args.mode = "nothing";
  }

  return Homey.flow.runFlowCardAction({
    uri: `homey:device:${vDevice.id}`,
    id: `homey:device:${vDevice.id}:${cardSuffix}`,
    args,
  });
};

// Format the current time in the configured local TZ. Using formatToParts
// because we want to assemble the string ourselves (date format differs
// from any built-in locale exactly enough to be annoying).
const stamp = () => {
  const parts = new Intl.DateTimeFormat("de-DE", {
    timeZone: TIMEZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(new Date());
  const get = (t) => parts.find((p) => p.type === t).value;
  return `${get("hour")}:${get("minute")} (${get("day")}-${get("month")}-${get("year")})`;
};

// Hour-of-day in the configured local TZ. Plain `date.getHours()` returns
// UTC on Athom Cloud, which would shift our heating window by 2-3 hours.
const localHour = (date) =>
  Number(
    new Intl.DateTimeFormat("en-US", {
      timeZone: TIMEZONE,
      hour: "2-digit",
      hour12: false,
    }).format(date),
  );

// Effective window start: pulled forward to EARLY_START_HOUR_H on warm mornings
// (ambient >= EARLY_START_AMBIENT_C), else the regular HEATING_WINDOW_START_H.
// Non-numeric ambient → regular start, never early, never throws. Defensive:
// the live path reads ambient via readNumber (which throws on non-numbers), so
// this only matters for direct unit tests of decide().
const effectiveStartHour = (ambient) =>
  typeof ambient === "number" && ambient >= EARLY_START_AMBIENT_C
    ? EARLY_START_HOUR_H
    : HEATING_WINDOW_START_H;

const inHeatingWindow = (date, ambient) => {
  const h = localHour(date);
  return h >= effectiveStartHour(ambient) && h < HEATING_WINDOW_END_H;
};

// --- decision -------------------------------------------------------------

/**
 * Returns {action, mode, reason}.
 *   action: 'heat' | 'idle' | 'noop'
 *   mode:   'silent' | 'smart' | 'boost' | null
 *   reason: human-readable why-string (also written to virtual device)
 *
 * Precedence (top wins):
 *   1. Power OFF                → idle (kill switch)
 *   2. Pool >= target + hyst    → idle (UPPER bound — even Boost respects
 *                                  this; once hot enough, no point burning
 *                                  more energy)
 *   3. Hard floor (ambient<18)  → idle (compressor protection — even Boost
 *                                  respects this; below ~18°C COP is awful and
 *                                  defrost cycles eat energy. Placed BEFORE
 *                                  Boost so "heat now" can't drag the pump into
 *                                  cold-weather operation.)
 *   4. Boost ON                 → HEAT (boost mode). Skips the heating window,
 *                                  the soft floor, AND the deadband hold below.
 *                                  "Heat now, I'll pay for it." Still bounded by
 *                                  steps 2 (upper) and 3 (hard floor).
 *   5. Deadband hold            → idle when currently OFF and pool is still
 *                                  above target - hyst. Second half of the
 *                                  hysteresis: after stopping at the upper
 *                                  bound, stay off while cooling until pool
 *                                  drops to target - hyst, then resume. Prevents
 *                                  on/off thrash. If currently HEATING (or pool
 *                                  already <= target - hyst) it falls through
 *                                  and keeps/starts heating.
 *   6. Outside heating window   → idle. Guards nighttime heat-retention, not
 *                                  COP. The morning start pulls forward to
 *                                  EARLY_START_HOUR_H when ambient is already
 *                                  >= EARLY_START_AMBIENT_C (warm = good COP).
 *   7. Soft floor (ambient<22)  → idle (suggests Boost as the override path)
 *   8. Otherwise                → HEAT, mode by gap-to-target
 *
 * Note: under Boost, the cron tick reaffirms heat each cycle, so the
 * 5-min reconciler does NOT fight the user — it just keeps re-sending
 * `on`/`mode-boost` (which the pump no-ops because already-set).
 */
const decide = ({
  intentOn,
  boostOverride,
  ambient,
  poolTemp,
  targetTemp,
  heatingNow,
  now,
}) => {
  // 1. Power OFF — kill switch, overrides everything.
  if (!intentOn) return { action: "idle", mode: null, reason: "intent OFF" };

  // 2. Upper bound — pool hot enough, stop. Even Boost stops here.
  if (
    typeof poolTemp === "number" &&
    poolTemp >= targetTemp + TARGET_HYSTERESIS_C
  ) {
    return {
      action: "idle",
      mode: null,
      reason: `pool ${poolTemp}°C ≥ target ${targetTemp}+${TARGET_HYSTERESIS_C}°C`,
    };
  }

  // 3. Hard floor — true compressor protection. Even Boost respects this:
  // below ~18°C ambient the COP is awful and defrost cycles start eating
  // energy (manual: pump operates -15..43°C). Placed BEFORE Boost so "heat
  // now" can't drag the pump into cold-weather operation.
  if (ambient < AMBIENT_HARD_FLOOR_C)
    return {
      action: "idle",
      mode: null,
      reason: `ambient ${ambient}°C < hard floor ${AMBIENT_HARD_FLOOR_C}°C`,
    };

  // 4. Boost = "heat now". User opt-in to inefficient heating in exchange for
  // speed. Skips the heating window, the soft floor, AND the deadband hold
  // below — but NOT the upper bound (step 2) or the hard floor (step 3).
  if (boostOverride) {
    return {
      action: "heat",
      mode: "boost",
      reason: `BOOST: heating to ${targetTemp}°C, ignoring window/soft-floor`,
    };
  }

  // 5. Deadband hold — second half of the hysteresis. Step 2 already idled
  // anything >= target+hyst; here, if the pump is currently OFF and the pool
  // hasn't yet fallen to target-hyst, keep it off so we don't re-fire on the
  // way down (real deadband, not bang-bang). If currently HEATING, or the
  // pool is already <= target-hyst, fall through and (keep) heating. Boost
  // skips this — it forces heat below the upper bound.
  if (
    typeof poolTemp === "number" &&
    poolTemp > targetTemp - TARGET_HYSTERESIS_C &&
    !heatingNow
  ) {
    return {
      action: "idle",
      mode: null,
      reason: `pool ${poolTemp}°C in deadband, holding off until ≤ ${round1(targetTemp - TARGET_HYSTERESIS_C)}°C`,
    };
  }

  // 6. Outside heating window — guards nighttime heat-retention (a heated pool
  // bleeds heat to the cold night sky / evaporation faster than the pump adds
  // it). NOT a COP gate: COP tracks air temp, and a warm post-sunrise morning
  // pulls the start forward to EARLY_START_HOUR_H (see effectiveStartHour).
  if (!inHeatingWindow(now, ambient)) {
    return {
      action: "idle",
      mode: null,
      reason: `outside heating window (allowed ${effectiveStartHour(ambient)}-${HEATING_WINDOW_END_H}; early start ${EARLY_START_HOUR_H} if ambient ≥ ${EARLY_START_AMBIENT_C}°C)`,
    };
  }

  // 7. Soft floor — surfaces Boost as the explicit override path.
  if (ambient < AMBIENT_SOFT_FLOOR_C) {
    return {
      action: "idle",
      mode: null,
      reason: `ambient ${ambient}°C below soft floor ${AMBIENT_SOFT_FLOOR_C}°C (toggle Boost to override)`,
    };
  }

  // 8. Heat. Default = silent (highest COP). Optionally upgrade to smart
  // when the gap-to-target exceeds SMART_GAP_C — set SMART_GAP_C = 0 to
  // disable the upgrade entirely (energy-saving default). If the upgrade
  // is disabled and the pump is currently in smart, reconcile() snaps it
  // back to silent via the wantSilent && !isSilent branch.
  let mode = "silent";
  if (
    SMART_GAP_C > 0 &&
    typeof poolTemp === "number" &&
    targetTemp - poolTemp > SMART_GAP_C
  ) {
    mode = "smart";
  }
  const reasonGap =
    typeof poolTemp === "number"
      ? `gap ${round1(targetTemp - poolTemp)}°C`
      : "pool temp unknown";
  return {
    action: "heat",
    mode,
    reason: `heating ${mode} (ambient ${ambient}°C, ${reasonGap})`,
  };
};

// Reconcile: send commands only if the pump's current state differs from
// what `decide` wants. Avoids hammering the wire with no-op writes.
//
// Reconciles four orthogonal aspects, in order:
//   1. Setpoint - sync user's target_temperature into pump's stored
//      setpoint via the pure `set-target` verb (no on/off side effects).
//   2. Model - force STATUS_MODE = 1 (heat). Pool only ever heats; if the
//      pump drifted to cool/auto somehow, snap it back. Idempotent.
//   3. Switch - on/off based on decision.action.
//   4. Function - silent/smart/boost based on decision.mode (only when on).
const reconcile = async (decision, snap, targetTemp) => {
  const pumpOn = snap?.SWITCHED_ON === 1 || snap?.SWITCHED_ON === true;
  const pumpMode = snap?.STATUS_MODE; // 1=heat, 2=auto, 4=cool (panel-confirmed)
  const isBoost = snap?.BOOST === 1 || snap?.BOOST === true;
  const isSilent = snap?.SILENCE === 1 || snap?.SILENCE === true;

  const sentVerbs = [];

  // 1. Setpoint sync - always, regardless of pump state. Pump stores it
  // persistently and will use it on the next on-cycle. Uses the pure
  // `set-target` verb (single FC=0x06 to the setpoint register, no other
  // side effects — distinct from `settemp` which also turns the pump on).
  if (
    typeof snap?.TEMP_TARGET === "number" &&
    typeof targetTemp === "number" &&
    snap.TEMP_TARGET !== targetTemp
  ) {
    await pumpCommand(`set-target ${targetTemp}`);
    sentVerbs.push(`set-target ${targetTemp}`);
  }

  // 2. Model = heat enforcement. Pool only ever heats - if the pump
  // drifted to auto (STATUS_MODE=2) or cool (4), snap it back. Idempotent
  // single-register write via the existing `setmode heat` verb.
  if (pumpMode !== 1) {
    await pumpCommand("setmode heat");
    sentVerbs.push("setmode heat");
  }

  // 3. Switch on/off based on decision.
  if (decision.action === "heat" && !pumpOn) {
    await pumpCommand("on");
    sentVerbs.push("on");
  } else if (decision.action === "idle" && pumpOn) {
    await pumpCommand("off");
    sentVerbs.push("off");
  }

  // 4. Function (silent/smart/boost) - only meaningful when heating.
  // decide() returns mode in {silent, smart, boost}. Snap pump-side to
  // match. The mode-auto branch covers the smart case (raw 0x0000 =
  // neither silent nor boost bit set); it also fires when SMART_GAP_C
  // is enabled and the pump needs to leave silent/boost for smart.
  if (decision.action === "heat") {
    const wantSilent = decision.mode === "silent";
    const wantBoost = decision.mode === "boost";
    if (wantSilent && !isSilent) {
      await pumpCommand("mode-silent");
      sentVerbs.push("mode-silent");
    }
    if (wantBoost && !isBoost) {
      await pumpCommand("mode-boost");
      sentVerbs.push("mode-boost");
    }
    if (!wantSilent && !wantBoost && (isSilent || isBoost)) {
      await pumpCommand("mode-auto");
      sentVerbs.push("mode-auto"); // 'smart' = neither bit
    }
  }
  return sentVerbs;
};

// --- main -----------------------------------------------------------------

const now = new Date();
const devices = await Homey.devices.getDevices();
const vDevice = findDevice(devices, VDEVICE_NAME);
const netatmo = findDevice(devices, NETATMO_OUTDOOR_NAME);

// Read intent (from the virtual device the user toggles).
// `target_temperature` is the Homey thermostat-style capability the user
// edits via the device tile / the thermostat target_temperature_set trigger.
// We deliberately do NOT read `number6` (Target Temperature Set) because
// that field is OUTPUT - reflects the pump's current setpoint, not user intent.
const intentOn = Boolean(
  vDevice.capabilitiesObj?.[
    `onoffbuttontab_devicecapabilities_button-custom_6.${VFIELD.power_intent.id}`
  ]?.value,
);
const boostOverride = Boolean(
  vDevice.capabilitiesObj?.[
    `onoffbuttontab_devicecapabilities_button-custom_24.${VFIELD.boost_intent.id}`
  ]?.value,
);
const targetTempRaw = vDevice.capabilitiesObj?.target_temperature?.value;
if (typeof targetTempRaw !== "number") {
  throw new Error(
    `"${VDEVICE_NAME}" missing target_temperature - set it on the device tile first`,
  );
}
const targetTemp = targetTempRaw;

// Read ground-truth ambient (Netatmo agrees with PQ03 within 1C per project memory)
const ambientNetatmo = readNumber(netatmo, "measure_temperature");

// Read current pump state. If pump is unreachable, abort cleanly - don't
// try to issue commands blind.
let snap = null;
let snapErr = null;
try {
  snap = await pumpStatus();
} catch (e) {
  snapErr = e.message;
}

// Pool temp source. Preference depends on EXTERNAL_POOL_TEMP_SENSOR:
//   external-sensor mode → reflected vDev value > pump inlet > pump outlet
//   pump mode (default)  → pump inlet > pump outlet > stale vDev value
// TEMP_INLET (CONFIRMED, block 1000 / addr 1001, 0.1°C precision) is water
// RETURNING from pool to pump — best single-sensor proxy in pump mode.
// TEMP_OUTLET is water LEAVING the pump; biased 2-5°C high while heating,
// equals inlet when pump is off and pipes have equalized.
const inletFromPump =
  snap && typeof snap.TEMP_INLET === "number" ? snap.TEMP_INLET : null;
const outletFromPump =
  snap && typeof snap.TEMP_OUTLET === "number" ? snap.TEMP_OUTLET : null;
const vDevPoolTemp = vDevice.capabilitiesObj?.measure_temperature?.value;
const externalSensorTemp =
  EXTERNAL_POOL_TEMP_SENSOR && typeof vDevPoolTemp === "number"
    ? vDevPoolTemp
    : null;
const poolTemp =
  externalSensorTemp ??
  inletFromPump ??
  outletFromPump ??
  (typeof vDevPoolTemp === "number" ? vDevPoolTemp : null);
// "True" = direct water-body sensor (external Zigbee or pump inlet);
// "false" = outlet proxy or stale vDev value.
const poolTempIsTrue = externalSensorTemp !== null || inletFromPump !== null;

// Current commanded on/off state — the hysteresis deadband needs it to "hold"
// inside the band (see decide() step 5). Mirrors reconcile()'s `pumpOn` read.
// Pump unreachable (snap=null) → false; reconcile() is skipped that tick, so
// this only affects the displayed status reason, never a command.
const heatingNow = snap?.SWITCHED_ON === 1 || snap?.SWITCHED_ON === true;

const decision = decide({
  intentOn,
  boostOverride,
  ambient: ambientNetatmo,
  poolTemp,
  targetTemp,
  heatingNow,
  now,
});

console.log(
  `[decision] action=${decision.action} mode=${decision.mode ?? "-"} reason="${decision.reason}"`,
);
console.log(
  `[inputs]  intent=${intentOn} boost=${boostOverride} ambient=${ambientNetatmo}°C pool=${poolTemp ?? "?"}°C target=${targetTemp}°C`,
);

let sentVerbs = [];
if (snap) {
  try {
    sentVerbs = await reconcile(decision, snap, targetTemp);
    if (sentVerbs.length)
      console.log(`[reconcile] sent: ${sentVerbs.join(", ")}`);
    else console.log(`[reconcile] no-op (pump already in desired state)`);
  } catch (e) {
    console.log(`[reconcile] FAILED: ${e.message}`);
  }
} else {
  console.log(`[reconcile] SKIPPED - pump unreachable: ${snapErr}`);
}

// Push telemetry into the virtual device for the dashboard view. We
// always update so the operator sees a fresh "Last Updated" timestamp
// even when nothing changed - that itself is proof the script ran.
const updates = [];
if (snap) {
  // pool_temp → number1 (Temperature Measured) → mirrors to standard
  // measure_temperature → updates the thermostat gauge's "Current
  // temperature" small number. Same flow card pattern as ambient/outlet
  // (`virtualdevice_set_number` with field id `number1`); the magic that
  // makes this update measure_temperature is the DC field's internal
  // mirror config — invisible from outside, but proven by the manual
  // "Set Temperature (Measured) to N" test card the user added.
  // Skipped when EXTERNAL_POOL_TEMP_SENSOR is on: the field is then
  // Reflect-bound to a dedicated sensor and writing here would fight it.
  if (!EXTERNAL_POOL_TEMP_SENSOR && typeof poolTemp === "number")
    updates.push(setVField(vDevice, "pool_temp", poolTemp));
  if (typeof snap.TEMP_AMBIENT === "number")
    updates.push(setVField(vDevice, "ambient", snap.TEMP_AMBIENT));
  if (typeof snap.TEMP_OUTLET === "number")
    updates.push(setVField(vDevice, "outlet", snap.TEMP_OUTLET));
  if (typeof snap.COMPRESSOR_RATE === "number")
    updates.push(setVField(vDevice, "compressor", snap.COMPRESSOR_RATE));
  // Power consumption estimate (W). Calibration 2026-05-12 against the
  // house grid meter delta (pool on - off = 1.80 kW at compressor 50%,
  // DC_LINK 355V × 6A): V_dc × I_dc × 0.85 predicted 1810 W (0.6% match).
  // BLL field is Show-As = Power (measure_power), so the value also shows
  // up under "Power Usage" in Insights — same data, two display contexts.
  // Falls back nil if either DC sensor is absent (pump just reconnected,
  // sensor block not yet pushed, etc.).
  const powerW =
    typeof snap.DC_LINK_VOLTAGE_V === "number" &&
    typeof snap.DC_LINK_CURRENT_A === "number"
      ? Math.round(snap.DC_LINK_VOLTAGE_V * snap.DC_LINK_CURRENT_A * 0.85)
      : null;
  if (typeof powerW === "number")
    updates.push(setVField(vDevice, "power_w", powerW));
  // Pool-temp display: the device's `measure_temperature` is a read-only
  // mirror of the DeviceCapabilities Status field
  // (measure_devicecapabilities_number-custom_26.status1) - direct
  // setCapabilityValue throws "Capability Not Setable". The cleanest path
  // is the DeviceCapabilities `virtualdevice_set_status` flow card, but its
  // exact arg shape isn't documented and the existing flow never used it.
  // For now we rely on `number5` (Outlet) to surface the same value -
  // the operator can read pool temp from that field. Re-enable a dedicated
  // write here once we confirm the Status flow card's arg shape from the UI.
  //
  // Mode display: the list1 field was removed from the device since pool
  // only heats - no need to show cool/auto. The pump's actual function
  // (silent/smart/boost) and on/off state are visible via Compressor Rate
  // (0 Hz = off) and the Last Updated reason text.
}
// Update the Status field (which feeds the big "Temperature" tile and
// the thermostat's small "current" reading). The capability isn't directly
// settable - "Missing Capability Listener" - so we go through the
// DeviceCapabilities `virtualdevice_set_status` flow card. Args mirror
// `virtualdevice_set_number` based on the existing flow's pattern.
// Wrapped in try/catch so an unknown-arg-shape rejection here doesn't
// kill the whole run.
if (typeof poolTemp === "number") {
  try {
    await Homey.flow.runFlowCardAction({
      uri: `homey:device:${vDevice.id}`,
      id: `homey:device:${vDevice.id}:virtualdevice_set_status`,
      args: {
        field: { id: "status1", name: "Status" },
        number: poolTemp,
        mode: "nothing",
      },
    });
  } catch (e) {
    console.log(`[status-write] flow-card failed (proceeding): ${e.message}`);
  }
}

// Last-updated text doubles as the decision-reason line AND surfaces the
// most operationally important values inline. After the device tile got
// hard to read at-a-glance (multiple "28"s with different meanings), the
// inlined `pool=NN°C ambient=NN°C target=NN°C` makes the operator's primary
// question - "what's the pool temperature right now" - answerable from this
// one line, regardless of whether the Status field write above succeeded.
// `text1` (Last Updated) holds only the timestamp - per-tile numbers
// already show the values that matter, and a long status string wraps
// unreadably under the cloud icon.
updates.push(setVField(vDevice, "last_updated", stamp()));

// `text2` (OperatingStatus) carries the decision/reason in a compact
// human-readable form. Faults are NO LONGER mixed in here — they live in
// their own `text3` (current_errors) field so both views are visible
// simultaneously on the tile. Examples:
//   "IDLE: ambient 20.7°C below soft floor 22°C"
//   "HEATING silent (gap 7.4°C, load 56%)"
//   "PUMP UNREACHABLE — last known state shown"
const operatingStatus = (() => {
  if (!snap) return "PUMP UNREACHABLE — last known values shown";
  const loadPct = snap.COMPRESSOR_LOAD_PCT;
  const loadPart =
    typeof loadPct === "number" && loadPct > 0 ? `, load ${loadPct}%` : "";
  if (decision.action === "heat") {
    const reasonGap = decision.reason.match(/gap [\d.]+°C/)?.[0] ?? "";
    const inner = [reasonGap, loadPart.replace(/^,\s*/, "")]
      .filter(Boolean)
      .join(", ");
    return `HEATING ${decision.mode}${inner ? ` (${inner})` : ""}`;
  }
  if (decision.action === "idle") {
    return `IDLE: ${decision.reason
      .replace(/^intent\s+/i, "")
      .replace(/\s*\(boost off\)$/, "")}`;
  }
  return decision.reason;
})();
updates.push(setVField(vDevice, "operating_status", operatingStatus));

// `text3` (current_errors) — fault description ONLY, empty when healthy.
// Lets the operator see the fault text without it eclipsing the heating
// state in operating_status.
const currentErrors =
  snap && snap.STATUS_MALFUNC && snap.STATUS_MALFUNC !== "none"
    ? `⚠ ${snap.STATUS_MALFUNC}`
    : "";
updates.push(setVField(vDevice, "current_errors", currentErrors));

// `boolean3` (pump_running) — derived "is the compressor actually working
// right now". True iff the user-intent switch is on AND the pump reports
// non-zero compressor frequency. Insights graphs the on/off transitions —
// useful for daily run-time totals and "did it heat overnight" timelines.
//
// `boolean4` (pump_error) — Show-As alarm_pump_device → standard pump-
// alarm UI (red dot + alarm-system integration). GATED on pump_running:
// many fault codes (notably P01 "no water flow") are physically
// meaningless when the pump isn't moving water, so they'd scream red
// every idle minute and train the operator to ignore the alarm. The
// underlying fault text stays visible in current_errors regardless —
// gating only suppresses the screaming alarm, not the diagnostic info.
//
// Both writes are skipped when snap is unavailable so a transient
// comms outage doesn't flip the alarm or running indicator spuriously.
if (snap) {
  const pumpRunning =
    snap.SWITCHED_ON === 1 &&
    typeof snap.COMPRESSOR_RATE === "number" &&
    snap.COMPRESSOR_RATE > 0;
  const hasFault = !!(snap.STATUS_MALFUNC && snap.STATUS_MALFUNC !== "none");
  updates.push(setVField(vDevice, "pump_running", pumpRunning));
  updates.push(setVField(vDevice, "pump_error", pumpRunning && hasFault));
}

await Promise.all(updates);

return {
  ok: true,
  decision,
  inputs: {
    intentOn,
    boostOverride,
    ambient: ambientNetatmo,
    poolTemp,
    targetTemp,
  },
  pumpReachable: !!snap,
  sent: sentVerbs,
  reason: decision.reason,
};
