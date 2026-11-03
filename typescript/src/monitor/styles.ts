/**
 * The monitor's style: plain CSS with variables, light and dark. No Tailwind,
 * no font from a CDN, no inline style attribute, so a strict CSP is enough.
 * Override --alpr-* on the element or an ancestor to match your site;
 * data-theme="light" or "dark" on the element forces a theme, otherwise it
 * follows the system.
 */
export const monitorCss = `.alpr-monitor{--alpr-fg:#0d1117;--alpr-muted:#57606a;--alpr-bg:#ffffff;--alpr-surface:#f6f8fa;--alpr-border:#d0d7de;--alpr-accent:#0d1117;--alpr-accent-fg:#ffffff;--alpr-ok:#067647;--alpr-ok-bg:#dcfae6;--alpr-danger:#b42318;--alpr-danger-bg:#fee4e2;--alpr-warn:#93370d;--alpr-warn-bg:#fef0c7;--alpr-radius:10px;--alpr-font:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;box-sizing:border-box;display:grid;gap:1rem;color:var(--alpr-fg);background:var(--alpr-bg);font-family:var(--alpr-font);font-size:.9375rem;line-height:1.45}
@media (prefers-color-scheme:dark){.alpr-monitor[data-theme="auto"]{--alpr-fg:#e6edf3;--alpr-muted:#8b949e;--alpr-bg:#0d1117;--alpr-surface:#161b22;--alpr-border:#30363d;--alpr-accent:#e6edf3;--alpr-accent-fg:#0d1117;--alpr-ok:#75e0a7;--alpr-ok-bg:#053321;--alpr-danger:#fda29b;--alpr-danger-bg:#55160c;--alpr-warn:#fec84b;--alpr-warn-bg:#4e1d09}}
.alpr-monitor[data-theme="dark"]{--alpr-fg:#e6edf3;--alpr-muted:#8b949e;--alpr-bg:#0d1117;--alpr-surface:#161b22;--alpr-border:#30363d;--alpr-accent:#e6edf3;--alpr-accent-fg:#0d1117;--alpr-ok:#75e0a7;--alpr-ok-bg:#053321;--alpr-danger:#fda29b;--alpr-danger-bg:#55160c;--alpr-warn:#fec84b;--alpr-warn-bg:#4e1d09}
.alpr-monitor *,.alpr-monitor *::before,.alpr-monitor *::after{box-sizing:inherit}
.alpr-monitor__header{display:flex;flex-wrap:wrap;gap:.75rem;align-items:flex-start;justify-content:space-between}
.alpr-monitor__title{margin:0;font-size:1.5rem;font-weight:700;letter-spacing:-.02em}
.alpr-monitor__subtitle{margin:.125rem 0 0;color:var(--alpr-muted);font-size:.875rem}
.alpr-monitor__engine{display:flex;align-items:center;gap:.375rem;margin:.375rem 0 0;color:var(--alpr-muted);font-size:.75rem}
.alpr-monitor__dot{width:.5rem;height:.5rem;border-radius:50%;background:var(--alpr-ok)}
.alpr-monitor__engine.is-down .alpr-monitor__dot{background:var(--alpr-warn)}
.alpr-monitor__summary{display:grid;gap:.75rem;grid-template-columns:repeat(auto-fit,minmax(11rem,1fr))}
.alpr-monitor__card{padding:.875rem 1rem;border:1px solid var(--alpr-border);border-radius:var(--alpr-radius);background:var(--alpr-bg)}
.alpr-monitor__card p{margin:0}
.alpr-monitor__card-label{font-size:.8125rem;font-weight:600}
.alpr-monitor__card-value{margin-top:.25rem!important;font-size:1.75rem;font-weight:700;font-variant-numeric:tabular-nums}
.alpr-monitor__card-note{color:var(--alpr-muted);font-size:.75rem}
.alpr-monitor__toolbar{display:flex;flex-wrap:wrap;gap:.75rem;align-items:flex-end}
.alpr-monitor__field{display:grid;gap:.25rem;font-size:.8125rem;font-weight:600}
.alpr-monitor__field--grow{flex:1 1 14rem}
.alpr-monitor__input{width:100%;min-height:2.25rem;padding:.375rem .625rem;color:var(--alpr-fg);background:var(--alpr-bg);border:1px solid var(--alpr-border);border-radius:calc(var(--alpr-radius) - 2px);font:inherit;font-weight:400}
.alpr-monitor__button{min-height:2.25rem;padding:.375rem .875rem;color:var(--alpr-fg);background:var(--alpr-bg);border:1px solid var(--alpr-border);border-radius:calc(var(--alpr-radius) - 2px);font:inherit;font-weight:600;cursor:pointer}
.alpr-monitor__button:hover:not(:disabled){background:var(--alpr-surface)}
.alpr-monitor__button:disabled{cursor:progress;opacity:.6}
.alpr-monitor__button--quiet{border-color:transparent;background:transparent;color:var(--alpr-muted)}
.alpr-monitor :focus-visible{outline:2px solid var(--alpr-accent);outline-offset:2px}
.alpr-monitor__alert{padding:.625rem .875rem;color:var(--alpr-danger);background:var(--alpr-danger-bg);border-radius:calc(var(--alpr-radius) - 2px)}
.alpr-monitor__alert a{color:inherit;font-weight:600}
.alpr-monitor__tablewrap{overflow-x:auto;border:1px solid var(--alpr-border);border-radius:var(--alpr-radius)}
.alpr-monitor__table{width:100%;border-collapse:collapse;text-align:left}
.alpr-monitor__table th,.alpr-monitor__table td{padding:.625rem .875rem;border-bottom:1px solid var(--alpr-border);vertical-align:middle}
.alpr-monitor__table thead th{color:var(--alpr-muted);background:var(--alpr-surface);font-size:.75rem;font-weight:600;text-transform:uppercase;letter-spacing:.04em}
.alpr-monitor__table tbody tr:last-child>*{border-bottom:0}
.alpr-monitor__name{font-weight:600}
.alpr-monitor__reads,.alpr-monitor__last{color:var(--alpr-muted);font-variant-numeric:tabular-nums}
.alpr-monitor__reads strong{color:var(--alpr-fg)}
.alpr-monitor__empty td{padding:1.5rem;color:var(--alpr-muted);text-align:center}
.alpr-monitor__badge{display:inline-block;padding:.125rem .5rem;border-radius:999px;font-size:.75rem;font-weight:600;color:var(--alpr-muted);background:var(--alpr-surface);border:1px solid var(--alpr-border)}
.alpr-monitor__badge--online{color:var(--alpr-ok);background:var(--alpr-ok-bg);border-color:transparent}
.alpr-monitor__badge--offline,.alpr-monitor__badge--expired{color:var(--alpr-danger);background:var(--alpr-danger-bg);border-color:transparent}
.alpr-monitor__badge--unknown{color:var(--alpr-warn);background:var(--alpr-warn-bg);border-color:transparent}
.alpr-monitor__note{margin:0;color:var(--alpr-muted);font-size:.8125rem}
.alpr-monitor__sr{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
@media (prefers-reduced-motion:no-preference){.alpr-monitor[aria-busy="true"] .alpr-monitor__tablewrap{transition:opacity .15s;opacity:.85}}
`;
