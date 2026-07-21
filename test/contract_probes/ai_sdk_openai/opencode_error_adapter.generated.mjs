import { Effect } from "effect";

export function applyOpenCodeErrorAdapter(event) {
  switch (event.type) {
    case "error":
          return Effect.fail(event.error)
    default:
      throw new Error("unsupported adapter event")
  }
}
