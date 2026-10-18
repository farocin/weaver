export function Card() {
  return (
    <column
      class="p-2 bg-red-500"
      background={{ type: "linear", stops: [{ offset: 0, color: "red-500" }, { offset: 1, color: "blue-500" }] }}
    >
      <text>hello</text>
    </column>
  );
}
