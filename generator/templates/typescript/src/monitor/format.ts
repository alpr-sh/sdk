import type { MonitorCamera, MonitorSnapshot } from "./types.ts";

/** The words of the screen: Brazilian Portuguese only. */
export const text = {
  title: "Monitor",
  subtitle: "Suas câmeras do Alpr.sh.",
  total: "Total de câmeras",
  totalNote: "Câmeras no Alpr.sh",
  online: "Online",
  onlineNote: "Lendo placas agora",
  offline: "Offline",
  offlineNote: "Sem leitura agora",
  readsToday: "Leituras hoje",
  readsMonth: "no mês",
  statusFilter: "Status",
  all: "Todos",
  search: "Buscar por nome da câmera…",
  searchLabel: "Buscar câmera",
  refresh: "Recarregar",
  clear: "Limpar filtros",
  name: "Nome",
  status: "Status",
  reads: "Leituras",
  today: "hoje",
  lastRead: "Última leitura",
  never: "Nunca",
  noReadYet: "Ainda sem leitura",
  cameras: "Câmeras",
  empty: "Nenhuma câmera encontrada.",
  noCameras: "Ainda não há câmeras neste espaço.",
  loading: "Carregando as câmeras…",
  engineOk: "Alpr.sh conectado",
  engineDown: "Leitura do Alpr.sh sem resposta",
  engineDownNote: "O status das câmeras pode estar desatualizado.",
  noAnswer: "Alpr.sh sem resposta",
  disabled: "Desativada",
  unknown: "Sem informação",
  expired: "Assinatura vencida",
  moreCameras: "Há mais câmeras do que as listadas.",
  renew: "Renovar assinatura",
  networkError: "Não foi possível carregar as câmeras agora. Tente de novo.",
  unauthorizedError: "A sessão do monitor expirou. Recarregue a página.",
  subscriptionError: "Assinatura inativa.",
  unavailableError: "O Alpr.sh não respondeu agora. Tente de novo.",
} as const;

/** The state of a camera, as the screen words it. */
export type StatusKey = "online" | "offline" | "disabled" | "expired" | "unknown";

/** Disabled, expired, online, offline or unknown: the engine being down makes the rest unknown. */
export function statusOf(camera: MonitorCamera, engine: MonitorSnapshot["engine"]): StatusKey {
  if (!camera.enabled) {
    return "disabled";
  }
  if (camera.status === "expired") {
    return "expired";
  }
  if (engine === "unavailable" || camera.online === null) {
    return "unknown";
  }
  return camera.online ? "online" : "offline";
}

/** The label of a status. */
export function statusLabel(key: StatusKey): string {
  switch (key) {
    case "online":
      return text.online;
    case "offline":
      return text.offline;
    case "disabled":
      return text.disabled;
    case "expired":
      return text.expired;
    default:
      return text.unknown;
  }
}

const UNITS: [Intl.RelativeTimeFormatUnit, number][] = [
  ["year", 31_536_000],
  ["month", 2_592_000],
  ["day", 86_400],
  ["hour", 3_600],
  ["minute", 60],
  ["second", 1],
];

/** "há 5 minutos": a time relative to now, in Portuguese. */
export function formatRelative(iso: string, now: number): string {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) {
    return "";
  }
  const seconds = Math.round((then - now) / 1000);
  const formatter = new Intl.RelativeTimeFormat("pt-BR", { numeric: "auto" });
  for (const [unit, size] of UNITS) {
    if (Math.abs(seconds) >= size || unit === "second") {
      return formatter.format(Math.trunc(seconds / size), unit);
    }
  }
  return "";
}

/** "22/10/2026 às 12:00", in the Alpr.sh zone (São Paulo). */
export function formatDateTime(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  const parts = new Intl.DateTimeFormat("pt-BR", { timeZone: "America/Sao_Paulo", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(date);
  const get = (type: string) => parts.find((part) => part.type === type)?.value ?? "";
  return `${get("day")}/${get("month")}/${get("year")} às ${get("hour")}:${get("minute")}`;
}

/** A count, or a dash when it is not known. */
export function count(value: number | null | undefined): string {
  return value === null || value === undefined ? "–" : new Intl.NumberFormat("pt-BR").format(value);
}
