using System.Runtime.Versioning;
using Ghostty.Bench.Transports;
using Xunit;

namespace Ghostty.Tests.Bench;

public class ConPtyTransportTests
{
    // No byte-for-byte stdin assertion: conhost line-buffers input, VT-
    // translates keys, and renders output as a screen, so echo symmetry
    // is not the right contract for a ConPTY regression guard.
    // The bounds are hang guards and nothing more: on a loaded machine the
    // conhost spawn and the first scheduled read can both take seconds, and
    // a budget tight enough to measure that is one that flakes on a busy
    // box. 60s still fails fast against the marshalling regression this
    // test exists for, which produces no output at all.
    [SupportedOSPlatform("windows")]
    [Fact(Timeout = 90_000)]
    public async Task Transport_DeliversConhostOutputWithinSeconds()
    {
        string childPath = Path.Combine(AppContext.BaseDirectory, "Ghostty.Bench.EchoChild.exe");
        Assert.True(File.Exists(childPath), $"EchoChild not copied: {childPath}");

        using var transport = new ConPtyTransport(childPath);

        // Require the child sentinel, not just a conhost preamble: a child with
        // invalid inherited standard handles can never write RDY to this PTY.
        var readTask = Task.Run(() =>
        {
            var buf = new byte[256];
            using var output = new MemoryStream();
            while (output.Length < 4096)
            {
                int count = transport.Output.Read(buf, 0, buf.Length);
                if (count <= 0) return false;
                output.Write(buf, 0, count);
                if (System.Text.Encoding.ASCII.GetString(output.ToArray()).Contains("RDY", StringComparison.Ordinal))
                    return true;
            }
            return false;
        });

        bool childReady;
        try
        {
            childReady = await readTask.WaitAsync(TimeSpan.FromSeconds(60));
        }
        catch (TimeoutException)
        {
            Assert.Fail("ConPtyTransport child did not emit RDY within 60s -- check pseudoconsole attachment and standard-handle isolation");
            throw; // unreachable: Assert.Fail throws, but satisfies definite-assignment.
        }

        Assert.True(childReady, "ConPtyTransport ended or exceeded its output bound before the child emitted RDY");
    }
}
