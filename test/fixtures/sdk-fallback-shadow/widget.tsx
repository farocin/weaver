import { widget } from "@weaver/sdk";

// `classes` captured the outer `size`; the inner one shadows it only below.
export default widget({ name: "SDK Fallback Shadow", size: [200, 100] }, () => {
  const size = "p-2";
  const classes = size;
  {
    const size = "p-4";
    return <column class={`${classes} bg-red-500`}><text>{size}</text></column>;
  }
});
