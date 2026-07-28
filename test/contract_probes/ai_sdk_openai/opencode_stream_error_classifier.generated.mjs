function json(input) {
    if (typeof input === "string") {
        try {
            const result = JSON.parse(input);
            if (result && typeof result === "object")
                return result;
            return undefined;
        }
        catch {
            return undefined;
        }
    }
    if (typeof input === "object" && input !== null) {
        return input;
    }
    return undefined;
}
export function parseStreamError(input) {
    const raw = json(input);
    const body = typeof raw?.message === "string" ? (json(raw.message) ?? raw) : raw;
    if (!body)
        return;
    const responseBody = JSON.stringify(body);
    if (body.type !== "error")
        return;
    switch (body?.error?.code) {
        case "context_length_exceeded":
            return {
                type: "context_overflow",
                message: "Input exceeds context window of this model",
                responseBody,
            };
        case "insufficient_quota":
            return {
                type: "api_error",
                message: "Quota exceeded. Check your plan and billing details.",
                isRetryable: false,
                responseBody,
            };
        case "usage_not_included":
            return {
                type: "api_error",
                message: "To use Codex with your ChatGPT plan, upgrade to Plus: https://chatgpt.com/explore/plus.",
                isRetryable: false,
                responseBody,
            };
        case "invalid_prompt":
            return {
                type: "api_error",
                message: typeof body?.error?.message === "string" ? body?.error?.message : "Invalid prompt.",
                isRetryable: false,
                responseBody,
            };
        case "server_is_overloaded":
        case "server_error":
            return {
                type: "api_error",
                message: typeof body?.error?.message === "string" ? body?.error?.message : "Server error.",
                isRetryable: true,
                responseBody,
            };
    }
}
