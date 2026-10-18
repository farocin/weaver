/**
 * An `<icon>`'s class: Lucide's 24px box first, so the author's utilities
 * win. `weaver bundle` compiles the same strings ahead of time, so both sides
 * build them here.
 */
export function iconClass(className: unknown): string {
  return `w-[24px] h-[24px] ${typeof className === "string" ? className : ""}`.trim();
}
