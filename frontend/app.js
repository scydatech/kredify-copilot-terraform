/* Kredify Copilot - staff web interface.
 * Sign-in: Cognito hosted UI, Authorization Code + PKCE (no client secret in the browser).
 * Tokens live in sessionStorage for this tab only and are refreshed with the refresh token.
 * Every answer is rendered from Markdown and sanitized with DOMPurify before display. */
(() => {
  "use strict";

  const CFG = window.KREDIFY_CONFIG || {};
  const CASE_GROUPS = new Set(CFG.caseDataGroups || ["kredify-financing-officers", "kredify-admins"]);
  const GROUNDING_THRESHOLD = typeof CFG.groundingThreshold === "number" ? CFG.groundingThreshold : 0.45;
  const TOKENS_KEY = "kc.tokens";
  const PKCE_KEY = "kc.pkce";
  const REQUEST_TIMEOUT_MS = 35000;

  const $ = (sel, root = document) => root.querySelector(sel);

  // ------------------------------------------------------------------ auth
  const b64url = (bytes) =>
    btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  const randomString = (n = 48) => b64url(crypto.getRandomValues(new Uint8Array(n)));

  async function sha256(text) {
    return crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  }

  function decodeJwt(token) {
    try {
      const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
      return JSON.parse(decodeURIComponent(escape(atob(part))));
    } catch {
      return {};
    }
  }

  const loadTokens = () => JSON.parse(sessionStorage.getItem(TOKENS_KEY) || "null");

  function saveTokens(t, previous = {}) {
    const tokens = {
      access: t.access_token,
      id: t.id_token || previous.id,
      refresh: t.refresh_token || previous.refresh,
      expiresAt: Date.now() + (t.expires_in || 3600) * 1000,
    };
    sessionStorage.setItem(TOKENS_KEY, JSON.stringify(tokens));
    return tokens;
  }

  async function tokenRequest(params) {
    const res = await fetch(`${CFG.cognitoDomain}/oauth2/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: CFG.clientId, ...params }),
    });
    if (!res.ok) throw new Error(`Token request failed (${res.status})`);
    return res.json();
  }

  async function startSignIn() {
    const verifier = randomString(64);
    const state = randomString(24);
    sessionStorage.setItem(PKCE_KEY, JSON.stringify({ verifier, state }));
    const url = new URL(`${CFG.cognitoDomain}/oauth2/authorize`);
    url.search = new URLSearchParams({
      response_type: "code",
      client_id: CFG.clientId,
      redirect_uri: CFG.redirectUri,
      scope: "openid email profile",
      code_challenge_method: "S256",
      code_challenge: b64url(await sha256(verifier)),
      state,
    });
    window.location.assign(url.toString());
  }

  async function completeSignIn(code, state) {
    const saved = JSON.parse(sessionStorage.getItem(PKCE_KEY) || "null");
    sessionStorage.removeItem(PKCE_KEY);
    history.replaceState(null, "", window.location.pathname);
    if (!saved || saved.state !== state) throw new Error("Sign-in could not be verified. Please sign in again.");
    return saveTokens(await tokenRequest({
      grant_type: "authorization_code",
      code,
      redirect_uri: CFG.redirectUri,
      code_verifier: saved.verifier,
    }));
  }

  async function refreshTokens(tokens) {
    if (!tokens || !tokens.refresh) return null;
    try {
      return saveTokens(await tokenRequest({ grant_type: "refresh_token", refresh_token: tokens.refresh }), tokens);
    } catch {
      sessionStorage.removeItem(TOKENS_KEY);
      return null;
    }
  }

  async function getAccessToken({ forceRefresh = false } = {}) {
    let tokens = loadTokens();
    if (tokens && (forceRefresh || Date.now() > tokens.expiresAt - 60000)) tokens = await refreshTokens(tokens);
    return tokens ? tokens.access : null;
  }

  function signOut() {
    sessionStorage.clear();
    const url = new URL(`${CFG.cognitoDomain}/logout`);
    url.search = new URLSearchParams({ client_id: CFG.clientId, logout_uri: CFG.redirectUri });
    window.location.assign(url.toString());
  }

  // ------------------------------------------------------------------ user & roles
  let canReadCases = false;

  function applyUser(tokens) {
    const claims = decodeJwt(tokens.id || tokens.access);
    const groups = new Set(claims["cognito:groups"] || []);
    canReadCases = [...groups].some((g) => CASE_GROUPS.has(g));

    $("#user-email").textContent = claims.email || "";
    $("#user-role").textContent =
      groups.has("kredify-admins") ? "Admin" :
      groups.has("kredify-financing-officers") ? "Financing officer" :
      groups.has("kredify-operations") ? "Operations" : "No copilot role";


    // Case data is enforced by the API; the UI just avoids offering what the role can't use.
    const caseTask = $('label[data-needs-case]');
    const caseInput = $("input", caseTask);
    caseInput.disabled = !canReadCases;
    caseTask.classList.toggle("is-locked", !canReadCases);
    if (!canReadCases) {
      caseTask.title = "Needs financing officer access";
      $("#merchant-field").hidden = true;
    }
  }

  // ------------------------------------------------------------------ form behaviour
  const PLACEHOLDERS = {
    explain_policy: "Ask about a Kredify financing policy",
    retrieve_info: "What do you need to find?",
    summarize_case: "What should the summary focus on? e.g. what is still needed",
    draft_response: "What should the message say? e.g. ask for the missing documents",
  };

  const currentTask = () => $('input[name="task"]:checked').value;

  function syncTask() {
    const task = currentTask();
    $("#question").placeholder = PLACEHOLDERS[task];
    const merchant = $("#merchant-id");
    merchant.required = task === "summarize_case";
    $("#merchant-hint").textContent = task === "summarize_case"
      ? "Required for a case summary."
      : "Optional. Adds the merchant's case record to the answer.";
  }

  function setStatus(text, isError = false) {
    const el = $("#status");
    el.textContent = text;
    el.classList.toggle("is-error", isError);
  }

  // ------------------------------------------------------------------ rendering
  const prettyDoc = (name) =>
    (name || "Document").replace(/\.[a-z0-9]+$/i, "").replace(/^kredify-/i, "").replace(/[-_]+/g, " ")
      .replace(/^\w/, (c) => c.toUpperCase());

  function renderAnswer(markdown, slipId) {
    let html = window.marked.parse(markdown || "", { breaks: false, gfm: true });
    // Turn [S1] / [S2, section 3] citations into links to the matching source in the evidence rail.
    html = html.replace(/\[(S\d+)([^\]<]{0,80})\]/g, (_, id, rest) =>
      `<a class="cite" href="#${slipId}-${id}">${id}${rest}</a>`);
    return window.DOMPurify.sanitize(html, { ALLOWED_URI_REGEXP: /^(#|https:)/i });
  }

  function renderEvidence(slip, data, task, slipId) {
    const evidence = $(".evidence", slip);
    const g = data.grounding;
    const label = $(".gauge-label", slip);
    const caption = $(".gauge-caption", slip);

    $(".gauge-tick", slip).style.left = `${Math.round(GROUNDING_THRESHOLD * 100)}%`;
    if (g && typeof g.score === "number") {
      const low = g.low_confidence ?? g.score < GROUNDING_THRESHOLD;
      evidence.classList.add(low ? "is-low" : "is-strong");
      label.textContent = low ? "Check against sources" : "Supported by sources";
      $(".gauge-value", slip).textContent = g.score.toFixed(2);
      requestAnimationFrame(() => { $(".gauge-fill", slip).style.width = `${Math.round(g.score * 100)}%`; });
      caption.textContent = `Grounding score. The line marks ${GROUNDING_THRESHOLD}; below it, verify before relying on the answer.`;
    } else {
      evidence.classList.add("is-unscored");
      label.textContent = task === "draft_response" ? "Not checked for drafts" : "Not scored";
      caption.textContent = task === "draft_response"
        ? "Drafts are reworded for merchants, so they aren't scored. Check each line against the sources."
        : "No grounding score was returned for this answer.";
    }

    const list = $(".sources", slip);
    const sources = data.sources || [];
    if (!sources.length) {
      list.innerHTML = '<li class="none">No approved documents matched this question.</li>';
      return;
    }
    for (const s of sources) {
      const li = document.createElement("li");
      li.id = `${slipId}-${s.id}`;
      const sid = document.createElement("span");
      sid.className = "sid";
      sid.textContent = s.id;
      li.appendChild(sid);

      const name = prettyDoc(s.document);
      if (s.url && /^https:\/\//.test(s.url)) {
        const a = document.createElement("a");
        a.href = s.url;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        a.textContent = name;
        a.title = "Opens the approved document. The link works for 15 minutes.";
        li.appendChild(a);
      } else {
        li.appendChild(document.createTextNode(name));
      }
      if (typeof s.score === "number") {
        const m = document.createElement("span");
        m.className = "match";
        m.textContent = `Match ${Math.round(s.score * 100)}%`;
        li.appendChild(m);
      }
      list.appendChild(li);
    }
  }

  let slipCounter = 0;

  function addSlip(question, task, merchantId) {
    $("#empty")?.remove();
    const slip = $("#slip-template").content.firstElementChild.cloneNode(true);
    const slipId = `a${++slipCounter}`;
    slip.id = slipId;
    const q = $(".slip-question", slip);
    q.textContent = question;
    const taskName = $(`input[value="${task}"]`).closest("label").querySelector("strong").textContent;
    const meta = document.createElement("span");
    meta.className = "meta";
    meta.textContent = merchantId ? `${taskName}, ${merchantId}` : taskName;
    q.appendChild(meta);
    $(".answer-text", slip).innerHTML = '<p class="pending">Checking approved documents…</p>';
    $(".evidence", slip).hidden = true;
    $(".copy", slip).hidden = true;
    $("#thread").appendChild(slip);
    slip.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "start" });
    return { slip, slipId };
  }

  function fillSlip(slip, slipId, data, task) {
    const answer = $(".answer-text", slip);
    const notice = $(".notice", slip);

    if (data.guardrail_intervened) {
      slip.classList.add("is-blocked");
      answer.textContent = data.answer || "This request can't be answered by the copilot.";
      return;
    }

    answer.innerHTML = renderAnswer(data.answer, slipId);
    $(".evidence", slip).hidden = false;
    renderEvidence(slip, data, task, slipId);

    if (data.grounding && data.grounding.low_confidence) {
      notice.className = "notice is-warning";
      notice.textContent = data.notice || "Some statements may not be directly supported by the cited sources. Verify before relying on this answer.";
      notice.hidden = false;
    } else if (task === "draft_response") {
      notice.className = "notice is-draft";
      notice.textContent = "Draft for your review. Remove the source references (S1, S2…) and check every line before sending.";
      notice.hidden = false;
    }

    const copy = $(".copy", slip);
    copy.hidden = false;
    copy.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(data.answer || "");
        copy.textContent = "Copied";
        setTimeout(() => { copy.textContent = "Copy answer"; }, 2000);
      } catch {
        copy.textContent = "Copy failed";
      }
    });
  }

  function failSlip(slip, message) {
    const notice = $(".notice", slip);
    notice.className = "notice is-error";
    notice.textContent = message;
    notice.hidden = false;
    $(".answer-text", slip).innerHTML = "";
  }

  // ------------------------------------------------------------------ API
  async function callCopilot(body, retried = false) {
    const token = await getAccessToken({ forceRefresh: retried });
    if (!token) {
      await startSignIn();
      throw new Error("Your session has ended. Redirecting to sign in…");
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    let res;
    try {
      res = await fetch(`${CFG.apiUrl}/v1/copilot`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } catch (err) {
      throw new Error(err.name === "AbortError"
        ? "The copilot took too long to answer. Try a narrower question."
        : "Couldn't reach the copilot. Check your connection and try again.");
    } finally {
      clearTimeout(timer);
    }

    if (res.status === 401 && !retried) return callCopilot(body, true);
    const data = await res.json().catch(() => ({}));
    if (res.ok) return data;

    const messages = {
      400: data.error || "The question couldn't be sent. Check the fields and try again.",
      401: "Your session has ended. Sign in again to continue.",
      403: data.error || "Your role doesn't allow this request.",
      429: "The copilot is busy. Wait a moment and try again.",
      503: "The copilot took too long to answer. Try a narrower question.",
      504: "The copilot took too long to answer. Try a narrower question.",
    };
    throw new Error(messages[res.status] || data.error || `The copilot returned an error (${res.status}). Try again.`);
  }

  async function onSubmit(event) {
    event.preventDefault();
    const questionEl = $("#question");
    const merchantEl = $("#merchant-id");
    const task = currentTask();
    const question = questionEl.value.trim();
    const merchantId = canReadCases ? merchantEl.value.trim() : "";

    if (!question) return questionEl.focus();
    if (task === "summarize_case" && !merchantId) {
      setStatus("Enter a merchant ID for a case summary.", true);
      return merchantEl.focus();
    }
    if (merchantId && !merchantEl.checkValidity()) {
      setStatus("Merchant ID can only contain letters, numbers, - and _.", true);
      return merchantEl.focus();
    }

    const body = { task, question };
    if (merchantId) body.merchant_id = merchantId;

    const ask = $("#ask");
    ask.disabled = true;
    questionEl.value = "";
    const started = Date.now();
    setStatus("Checking approved documents…");
    const ticker = setInterval(() => setStatus(`Checking approved documents… ${Math.round((Date.now() - started) / 1000)}s`), 1000);
    const { slip, slipId } = addSlip(question, task, merchantId);

    try {
      const data = await callCopilot(body);
      fillSlip(slip, slipId, data, task);
      setStatus("");
    } catch (err) {
      failSlip(slip, err.message);
      setStatus(err.message, true);
      if (!questionEl.value) questionEl.value = question;
    } finally {
      clearInterval(ticker);
      ask.disabled = false;
      questionEl.focus();
    }
  }

  // ------------------------------------------------------------------ boot
  function showGate(message, withButton) {
    $("#app").hidden = true;
    $("#gate").hidden = false;
    $("#gate-message").textContent = message;
    $("#sign-in").hidden = !withButton;
  }

  function showApp(tokens) {
    applyUser(tokens);
    syncTask();
    $("#gate").hidden = true;
    $("#app").hidden = false;
    $("#question").focus();
  }

  async function boot() {
    $("#sign-in").addEventListener("click", startSignIn);
    $("#sign-out").addEventListener("click", signOut);
    $("#composer").addEventListener("submit", onSubmit);
    document.querySelectorAll('input[name="task"]').forEach((r) => r.addEventListener("change", syncTask));
    $("#question").addEventListener("keydown", (e) => {
      if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) $("#composer").requestSubmit();
    });

    if (!CFG.apiUrl || !CFG.cognitoDomain || !CFG.clientId) {
      showGate("The copilot isn't configured. config.js is missing or incomplete.", false);
      return;
    }

    const params = new URLSearchParams(window.location.search);
    try {
      if (params.get("error")) {
        history.replaceState(null, "", window.location.pathname);
        showGate(`Sign-in was cancelled or failed (${params.get("error")}).`, true);
        return;
      }
      if (params.get("code")) {
        showApp(await completeSignIn(params.get("code"), params.get("state")));
        return;
      }
      const token = await getAccessToken();
      if (token) {
        showApp(loadTokens());
        return;
      }
      showGate("Sign in with your Kredify staff account to use the copilot.", true);
    } catch (err) {
      showGate(err.message, true);
    }
  }

  document.addEventListener("DOMContentLoaded", boot);
})();
