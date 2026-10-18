import { widget } from "@weaver/sdk";

// Numeric addition inside a template: the run-time class is p-[4px].
export default widget({ name: "SDK Fallback Numeric", size: [200, 100] }, () => (
  <column class={`p-[${2 + 2}px] bg-red-500`}><text>hello</text></column>
));
