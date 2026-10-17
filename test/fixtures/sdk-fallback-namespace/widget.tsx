import { widget } from "@weaver/sdk";
// The element factory, reached through a namespace re-export.
import { SDK } from "./factory";

export default widget({ name: "SDK Fallback Namespace", size: [200, 100] }, () =>
  SDK.h("column", { class: "p-2 bg-red-500" }, SDK.h("text", {}, "hello")));
