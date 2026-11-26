defmodule Weld.DocsSmokeTest do
  use ExUnit.Case, async: true

  alias Weld.DocsSmoke

  @moduletag :tmp_dir

  test "checks nested HTML pages and Mermaid classes in ordinary HTML attributes", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "index.html"), "<html></html>")
    File.mkdir_p!(Path.join(dir, "guides"))

    File.write!(
      Path.join(dir, "guides/architecture.html"),
      "<pre><code title='a > b' id='diagram' class='language-mermaid mermaid'>graph TD</code></pre>"
    )

    assert {:error, errors} = DocsSmoke.check(dir)
    assert Enum.any?(errors, &(&1 =~ "guides/architecture.html" and &1 =~ "mermaid.min.js"))
    assert Enum.any?(errors, &(&1 =~ "guides/architecture.html" and &1 =~ "exdoc:loaded"))
  end

  test "prose and comments cannot satisfy script and event listener checks", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "index.html"),
      """
      <pre><code class="mermaid">graph TD</code></pre>
      <p>Install mermaid.min.js and handle exdoc:loaded.</p>
      <!-- <script src="mermaid.min.js"></script>
      <script>window.addEventListener("exdoc:loaded", render)</script> -->
      """
    )

    assert {:error, errors} = DocsSmoke.check(dir)
    assert length(errors) == 2
  end

  test "recognizes a real loader and exdoc listener without counting markup inside scripts", %{
    tmp_dir: dir
  } do
    File.write!(
      Path.join(dir, "index.html"),
      """
      <pre><code class=mermaid>graph TD</code></pre>
      <script title='a > b' defer src='https://cdn.example/mermaid.min.js?v=1'></script>
      <script title="a > b">window.addEventListener('exdoc:loaded', render)</script>
      """
    )

    File.write!(
      Path.join(dir, "examples.html"),
      """
      <!-- <code class="mermaid">an example</code> -->
      <script>const example = '<code class="mermaid">';</script>
      <code>&lt;code class="mermaid"&gt;</code>
      """
    )

    assert {:ok, summary} = DocsSmoke.check(dir)
    assert summary.html_count == 2
    assert summary.mermaid_pages == ["index.html"]
  end

  test "a script which only mentions the event is not a navigation listener", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "index.html"),
      """
      <code class="mermaid">graph TD</code>
      <script src="mermaid.min.js"></script>
      <script>const eventName = "exdoc:loaded";</script>
      """
    )

    assert {:error, [error]} = DocsSmoke.check(dir)
    assert error =~ "exdoc:loaded"
  end

  test "division expressions around a real listener do not hide it", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "index.html"),
      """
      <code class="mermaid">graph TD</code>
      <script src="mermaid.min.js"></script>
      <script>
        const x = a / b; window.addEventListener('exdoc:loaded', render); const y = c / d;
      </script>
      """
    )

    assert {:ok, %{mermaid_pages: ["index.html"]}} = DocsSmoke.check(dir)
  end

  test "JavaScript examples and ignored external-script bodies do not register listeners", %{
    tmp_dir: dir
  } do
    examples = [
      "<script>// window.addEventListener('exdoc:loaded', render)</script>",
      "<script>/* window.addEventListener('exdoc:loaded', render) */</script>",
      """
      <script>const example = "window.addEventListener('exdoc:loaded', render)";</script>
      """,
      "<script>const example = `window.addEventListener('exdoc:loaded', render)`;</script>",
      "<script>const example = /window.addEventListener('exdoc:loaded', render)/;</script>",
      "<script src='other.js'>window.addEventListener('exdoc:loaded', render)</script>",
      "<script src=''>window.addEventListener('exdoc:loaded', render)</script>",
      "<script src>window.addEventListener('exdoc:loaded', render)</script>"
    ]

    for example <- examples do
      File.write!(
        Path.join(dir, "index.html"),
        "<code class='mermaid'>graph TD</code><script src='mermaid.min.js'></script>" <> example
      )

      assert {:error, [error]} = DocsSmoke.check(dir)
      assert error =~ "exdoc:loaded"
    end
  end
end
