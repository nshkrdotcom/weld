defmodule Weld.DocsPreviewTest do
  use ExUnit.Case, async: true

  test "stabilizes Makeup groups independently within each code block" do
    render = fn prefix ->
      """
      <p data-group-id="1111111111-4">Original prose</p>
      <code class="makeup elixir" translate="no"><span class="p" data-group-id="#{prefix}-1">[</span>ok<span class="p" data-group-id="#{prefix}-1">]</span></code>
      <code class="makeup elixir" translate="no"><span class="p" data-group-id="#{prefix}-1">[</span>again<span class="p" data-group-id="#{prefix}-1">]</span></code>
      <code class="other"><span class="p" data-group-id="1111111111-4">Foreign markup</span></code>
      """
    end

    canonical = Weld.DocsPreview.stable_groups(render.("1111111111"))
    assert canonical == Weld.DocsPreview.stable_groups(render.("2940072322"))
    assert length(Regex.scan(~r/data-group-id="weld-0-0-1"/, canonical)) == 2
    assert length(Regex.scan(~r/data-group-id="weld-1-0-1"/, canonical)) == 2
    assert length(Regex.scan(~r/data-group-id="1111111111-4"/, canonical)) == 2
  end
end
