defmodule CodexPooler.Gateway.RequestCompression.ContentDetectorTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.ContentDetector

  describe "detect/1 order" do
    test "classifies empty or whitespace-only content as text" do
      assert_noop(:text, ContentDetector.detect(" \n\t"))
    end

    test "detects nested JSON arrays before generic text handling" do
      body = ~S([{"label":"example result","values":[["nested","array"],{"status":"ok"}]}])

      assert %{
               kind: :json_array,
               confidence: 1.0,
               compressible: true,
               strategy: :json_array_lossless
             } = ContentDetector.detect(body)
    end

    test "keeps detector priority for ambiguous fixtures" do
      json_body = ~S([{"line":"diff --git a/example.txt b/example.txt"}])

      diff_body = """
      diff --git a/example.html b/example.html
      index 1111111..2222222 100644
      --- a/example.html
      +++ b/example.html
      @@ -1,2 +1,2 @@
      -<p>old example</p>
      +<p>new example</p>
      """

      html_body = """
      <!doctype html>
      <html>
        <body>
          <p data-kind="example">Search results for example query</p>
          <ol><li>1. example result - sanitized summary</li></ol>
        </body>
      </html>
      """

      search_body = """
      Search results for sanitized query:
      1. example result - warning line
      2. another result - error line
      """

      build_body = """
      ==> sample_app
      Compiling 1 file (.ex)
          defmodule Example.Module do
      warning: sanitized warning
      """

      assert %{kind: :json_array} = ContentDetector.detect(json_body)
      assert %{kind: :diff} = ContentDetector.detect(diff_body)
      assert_noop(:html, ContentDetector.detect(html_body))
      assert %{kind: :search} = ContentDetector.detect(search_body)
      assert %{kind: :build} = ContentDetector.detect(build_body)
    end
  end

  describe "confidence thresholds" do
    test "detects valid JSON arrays and top-level JSON objects" do
      assert %{kind: :json_array, confidence: 1.0} =
               ContentDetector.detect(~S([{"status":"ok"}]))

      assert %{
               kind: :json_document,
               confidence: 1.0,
               compressible: true,
               strategy: :json_document_lossless
             } = ContentDetector.detect(~S({"status":"ok"}))

      assert_noop(:text, ContentDetector.detect(~S([{"status":])))
    end

    test "detects git diffs at and above request-compression confidence" do
      positive = """
      --- a/example.txt
      +++ b/example.txt
      @@ -1 +1 @@
      -example old line
      +example new line
      """

      negative = """
      diff --git a/example.txt b/example.txt
      --- a/example.txt
      +++ b/example.txt
      """

      assert %{kind: :diff, confidence: confidence, compressible: true, strategy: :diff} =
               ContentDetector.detect(positive)

      assert confidence >= 0.7
      assert_noop(:text, ContentDetector.detect(negative))
    end

    test "detects one-sided and minimal unified hunks without diff git headers" do
      additions_only = """
      @@ -1,0 +1,3 @@
      +added one
      +added two
      +added three
      """

      deletions_only = """
      @@ -1,3 +1,0 @@
      -removed one
      -removed two
      -removed three
      """

      replacement = """
      @@ -1 +1 @@
      -old value
      +new value
      """

      for body <- [additions_only, deletions_only, replacement] do
        assert %{kind: :diff, confidence: confidence, compressible: true, strategy: :diff} =
                 ContentDetector.detect(body)

        assert confidence >= 0.7
      end
    end

    test "detects combined diffs without broadening prose detection" do
      combined = """
      diff --cc lib/example.ex
      index 1111111,2222222..3333333
      --- a/lib/example.ex
      +++ b/lib/example.ex
      @@@ -1,2 -1,2 +1,2 @@@
      -old left
      +new merged
       context line
      """

      preamble = """
      Here is the combined diff requested for review:

      #{combined}
      """

      assert %{kind: :diff, confidence: combined_confidence, compressible: true, strategy: :diff} =
               ContentDetector.detect(combined)

      assert combined_confidence >= 0.7

      assert %{kind: :diff, confidence: preamble_confidence, compressible: true, strategy: :diff} =
               ContentDetector.detect(preamble)

      assert preamble_confidence >= 0.7
    end

    test "keeps prose with isolated plus and minus lines out of diff detection" do
      prose = """
      Review notes for the next change:
      + add a short summary before the examples
      - remove the stale paragraph near the end
      """

      missing_hunk = """
      --- a/example.txt
      +++ b/example.txt
      +added without a hunk header
      -removed without a hunk header
      """

      assert_noop(:text, ContentDetector.detect(prose))
      assert_noop(:text, ContentDetector.detect(missing_hunk))
    end

    test "detects HTML at request-compression confidence but keeps it no-op" do
      positive = """
      <!doctype html>
      <html>
        <body><main><p data-kind="example">sanitized page</p></main></body>
      </html>
      """

      negative = "<section>example prose with one tag</section>"

      assert %{kind: :html, confidence: confidence} = decision = ContentDetector.detect(positive)
      assert confidence >= 0.7
      assert_noop(:html, decision)
      assert_noop(:text, ContentDetector.detect(negative))
    end

    test "detects search results at and above request-compression confidence" do
      positive = """
      Search results for sanitized query:
      1. example result title - example summary line
      2. another example result - another summary line
      """

      negative = """
      Search results for sanitized query:
      1. example result title - example summary line
      """

      assert %{
               kind: :search,
               confidence: confidence,
               compressible: true,
               strategy: :search_results
             } = ContentDetector.detect(positive)

      assert confidence >= 0.6
      assert_noop(:text, ContentDetector.detect(negative))
    end

    test "detects classic grouped and nul-delimited search output" do
      classic =
        1..3
        |> Enum.map_join("\n", &"lib/example_#{&1}.ex:#{&1}: found match #{&1}")

      grouped = """
      lib/grouped.ex
      12: first grouped match
      14:3: second grouped match
      """

      nul_delimited =
        1..3
        |> Enum.map_join("\n", &"lib/nul_result.ex\0#{&1}: nul match #{&1}")

      for body <- [classic, grouped, nul_delimited] do
        assert %{
                 kind: :search,
                 confidence: confidence,
                 compressible: true,
                 strategy: :search_results
               } = ContentDetector.detect(body)

        assert confidence >= 0.6
      end
    end

    test "keeps prose headings and malformed nul fragments out of search detection" do
      prose_heading = """
      Search results from the last review.
      1: this is prose, not a grouped file match
      2: this is also prose
      """

      malformed_nul = """
      lib/example.ex\0not-a-match-line
      lib/example.ex\0: missing line number
      lib/example.ex\0one: missing numeric line
      """

      assert_noop(:text, ContentDetector.detect(prose_heading))
      assert_noop(:text, ContentDetector.detect(malformed_nul))
    end

    test "detects build or log output at and above request-compression confidence" do
      positive = """
      example command output line
      example command output line
      warning: example warning without private details
      error: example failure without private details
      """

      negative = """
      warning example warning without private details
      ordinary prose after the warning
      """

      assert %{kind: :build, confidence: confidence, compressible: true, strategy: :log_output} =
               ContentDetector.detect(positive)

      assert confidence >= 0.5
      assert_noop(:text, ContentDetector.detect(negative))
    end

    test "detects compiler and linter diagnostics without command context" do
      dotnet = """
      /workspace/sample-app/Broken.cs(7,17): error CS1525: Invalid expression term ';' [/workspace/sample-app/sample-app.csproj]
          0 Warning(s)
          1 Error(s)

      Time Elapsed 00:00:00.76
      """

      biome = """
      src/app.tsx:5:3 lint/suspicious/noExplicitAny ━━━━━━━━━━━━━━━━━━━━
        × Unexpected any. Specify a different type.
        3 │ interface Props {
        4 │   data: any;
        5 │         ^^^

      Found 2 errors.
      """

      assert %{kind: :build, compressible: true, strategy: :log_output} =
               ContentDetector.detect(dotnet)

      assert %{kind: :build, compressible: true, strategy: :log_output} =
               ContentDetector.detect(biome)
    end

    test "detects source code at request-compression confidence but keeps it no-op" do
      positive = """
      defmodule Example.Module do
        def call(value) when is_binary(value) do
          {:ok, String.trim(value)}
        end
      end
      """

      negative = "This ordinary sentence mentions a function but is not code."

      assert %{kind: :source_code, confidence: confidence} =
               decision = ContentDetector.detect(positive)

      assert confidence >= 0.5
      assert_noop(:source_code, decision)
      assert_noop(:text, ContentDetector.detect(negative))
    end
  end

  describe "safe decision metadata" do
    test "does not include fixture content in the detector decision" do
      sentinel = "synthetic instruction marker"

      body = """
      Search results for sanitized query:
      1. #{sentinel} - example summary line
      2. another example result - another summary line
      """

      assert %{kind: :search} = decision = ContentDetector.detect(body)

      refute inspect(decision) =~ sentinel
      assert Map.keys(decision) |> Enum.sort() == [:compressible, :confidence, :kind, :strategy]
    end

    test "does not retain state between calls" do
      diff_body = """
      --- a/example.txt
      +++ b/example.txt
      @@ -1 +1 @@
      -example old line
      +example new line
      """

      assert %{kind: :diff} = ContentDetector.detect(diff_body)
      assert_noop(:text, ContentDetector.detect("ordinary sanitized prose"))
    end
  end

  defp assert_noop(kind, decision) do
    assert %{kind: ^kind, compressible: false, strategy: nil} = decision
  end
end
