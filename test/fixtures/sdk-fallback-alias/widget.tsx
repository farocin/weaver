import { widget } from "@weaver/sdk";

// An uppercase tag that is a built-in element's name, not a component.
export default widget({ name: "SDK Fallback Alias", size: [200, 100] }, () => {
  const Column = "column";
  const props = { class: "p-2 bg-red-500" };
  return <Column {...props}><text>hello</text></Column>;
});
