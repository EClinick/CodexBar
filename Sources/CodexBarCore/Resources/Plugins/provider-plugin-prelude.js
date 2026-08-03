(function applyProviderPluginPrelude(ctx, host) {
  "use strict";

  ctx.http = Object.freeze({
    getJSON(url, opts) {
      return new Promise((resolve, reject) => host.http(String(url), opts || {}, true, resolve, reject));
    },
    get(url, opts) {
      return new Promise((resolve, reject) => host.http(String(url), opts || {}, false, resolve, reject));
    },
  });

  ctx.secrets = Object.freeze({
    get(key) {
      return host.secretGet(String(key));
    },
  });

  ctx.log = (...args) => host.log(args.map(value => {
    if (typeof value === "string") return value;
    try { return JSON.stringify(value); } catch (_) { return String(value); }
  }).join(" "));

  ctx.cache = Object.freeze({
    get(key) {
      return host.cacheGet(String(key));
    },
    set(key, value, ttlSeconds) {
      host.cacheSet(String(key), value, Number(ttlSeconds));
    },
  });

  function parseDate(value) {
    const date = new Date(value);
    if (!Number.isFinite(date.getTime())) throw new TypeError("invalid date");
    return date;
  }

  function zonedParts(date, timeZone) {
    const formatter = new Intl.DateTimeFormat("en-US", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    });
    const values = {};
    for (const part of formatter.formatToParts(date)) {
      if (part.type !== "literal") values[part.type] = Number(part.value);
    }
    return values;
  }

  function zonedEpoch(year, month, day, hour, timeZone) {
    let guess = Date.UTC(year, month - 1, day, hour, 0, 0);
    for (let iteration = 0; iteration < 3; iteration += 1) {
      const parts = zonedParts(new Date(guess), timeZone);
      const represented = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
      guess += Date.UTC(year, month - 1, day, hour, 0, 0) - represented;
    }
    return guess;
  }

  function decodeBase64URL(text) {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const normalized = String(text).replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
    let bits = 0;
    let bitCount = 0;
    let output = "";
    for (const character of normalized) {
      const value = alphabet.indexOf(character);
      if (value < 0) throw new TypeError("invalid base64url data");
      bits = (bits << 6) | value;
      bitCount += 6;
      if (bitCount >= 8) {
        bitCount -= 8;
        output += String.fromCharCode((bits >> bitCount) & 0xff);
      }
    }
    let escaped = "";
    for (let index = 0; index < output.length; index += 1) {
      escaped += `%${output.charCodeAt(index).toString(16).padStart(2, "0")}`;
    }
    return decodeURIComponent(escaped);
  }

  ctx.date = Object.freeze({
    iso(value) { return parseDate(String(value)); },
    unixSeconds(value) { return parseDate(Number(value) * 1000); },
    unixMillis(value) { return parseDate(Number(value)); },
    nextDailyReset(timeZone, hour) {
      const resetHour = Number(hour);
      if (!Number.isInteger(resetHour) || resetHour < 0 || resetHour > 23) {
        throw new TypeError("reset hour must be an integer from 0 through 23");
      }
      const now = new Date();
      const parts = zonedParts(now, String(timeZone));
      let candidate = zonedEpoch(parts.year, parts.month, parts.day, resetHour, String(timeZone));
      if (candidate <= now.getTime()) {
        const tomorrow = new Date(Date.UTC(parts.year, parts.month - 1, parts.day) + 86400000);
        candidate = zonedEpoch(
          tomorrow.getUTCFullYear(),
          tomorrow.getUTCMonth() + 1,
          tomorrow.getUTCDate(),
          resetHour,
          String(timeZone));
      }
      return new Date(candidate);
    },
  });

  ctx.jwt = Object.freeze({
    decode(token) {
      const parts = String(token).split(".");
      if (parts.length < 2) throw new TypeError("JWT must contain a payload segment");
      return JSON.parse(decodeBase64URL(parts[1]));
    },
  });

  ctx.pct = (used, limit) => {
    const numericUsed = Number(used);
    const numericLimit = Number(limit);
    if (!Number.isFinite(numericUsed) || !Number.isFinite(numericLimit) || numericLimit <= 0) return 100;
    return Math.max(0, Math.min(100, numericUsed / numericLimit * 100));
  };

  return ctx;
})
