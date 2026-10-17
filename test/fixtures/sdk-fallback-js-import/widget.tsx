import { widget } from "@weaver/sdk";
// TypeScript and esbuild resolve "./card.js" to card.tsx; the class analysis
// may not see that file, so its class and background reach the fallback.
import { Card } from "./card.js";

export default widget({ name: "SDK Fallback Import", size: [200, 100] }, () => <Card />);
