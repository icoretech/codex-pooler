defmodule CodexPooler.Gateway.OpenAICompatibility.AccessProgramsTest do
  use ExUnit.Case, async: true

  @moduletag :access_programs

  alias CodexPooler.Gateway.OpenAICompatibility.Responses

  test "known cyber selections and empty selection survive coercion unchanged" do
    for programs <- [%{}, %{"cyber" => "standard"}, %{"cyber" => "daybreak_blue"}, %{"cyber" => "daybreak_red"}] do
      assert {:ok, %{payload: payload}} = Responses.coerce(%{"model" => "sample-model", "input" => "synthetic request", "access_programs" => programs})
      assert payload["access_programs"] == programs
    end
  end

  test "malformed selections are rejected without reflecting values" do
    for {programs, param} <- [{nil, "access_programs"}, {[], "access_programs"}, {"secret-value", "access_programs"}, {%{"cyber" => nil}, "access_programs.cyber"}, {%{"cyber" => "secret-value"}, "access_programs.cyber"}, {%{"cyber" => 1}, "access_programs.cyber"}, {%{"unknown" => "secret-value"}, "access_programs"}] do
      assert {:error, %{status: 400, code: "invalid_request", param: ^param} = error} = Responses.coerce(%{"model" => "sample-model", "input" => "synthetic request", "access_programs" => programs})
      refute inspect(error) =~ "secret-value"
    end
  end
end
