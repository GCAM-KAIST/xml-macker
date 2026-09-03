using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace XMLMacker.Core;

/// <summary>
/// A tiny append-only diagnostic logger + timing helper (Swift <c>enum Diag</c>). Used to profile where time
/// goes without an attached debugger.
///
/// Writes are <b>fire-and-forget, non-blocking, and error-swallowing</b>: callers never block and never see
/// exceptions. Lines are posted to a single-consumer <see cref="Channel{T}"/> that a dedicated long-lived
/// background task drains, appending to <c>%TEMP%\xmleditorx.log</c> (the WPF analog of the Swift serial dispatch queue).
/// </summary>
public static class Diag
{
    private static readonly string LogPath = Path.Combine(Path.GetTempPath(), "xmleditorx.log");

    // UTF-8 without a BOM, the Swift logger writes raw UTF-8 bytes with no preamble.
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

    private static readonly Channel<string> Queue = Channel.CreateUnbounded<string>(
        new UnboundedChannelOptions { SingleReader = true, SingleWriter = false });

    static Diag()
    {
        // Start the single long-lived background drain task, fire-and-forget. It is kept alive by the pending read on
        // the static <see cref="Queue"/> (the continuation roots the async state machine), so no field is needed.
        _ = Task.Run(DrainAsync);
    }

    /// <summary>
    /// Logs a message. The line is formatted <c>[&lt;iso8601&gt;] &lt;message&gt;\n</c> with an ISO-8601
    /// timestamp with fractional seconds (<c>"o"</c> format). Never throws; never blocks.
    /// </summary>
    public static void Log(string message)
    {
        try
        {
            Queue.Writer.TryWrite($"[{DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)}] {message}\n");
        }
        catch
        {
            // best-effort, swallow everything
        }
    }

    /// <summary>
    /// Lazy overload mirroring the Swift <c>@autoclosure</c>: the message is only built when logging runs.
    /// Never throws; never blocks.
    /// </summary>
    public static void Log(Func<string> messageFactory)
    {
        try
        {
            Queue.Writer.TryWrite($"[{DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)}] {messageFactory()}\n");
        }
        catch
        {
            // best-effort, swallow everything
        }
    }

    /// <summary>
    /// Runs <paramref name="block"/>, logs <c>"&lt;name&gt;: &lt;dt&gt;s"</c> where <c>dt</c> is the elapsed
    /// seconds formatted to 3 decimals (<c>F3</c>), and returns the block's result.
    /// </summary>
    public static T Time<T>(string name, Func<T> block)
    {
        var sw = Stopwatch.StartNew();
        T result = block();
        sw.Stop();
        Log($"{name}: {sw.Elapsed.TotalSeconds.ToString("F3", CultureInfo.InvariantCulture)}s");
        return result;
    }

    private static async Task DrainAsync()
    {
        try
        {
            await foreach (string line in Queue.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                try
                {
                    // AppendAllTextAsync creates the file if absent, appends otherwise (matches the Swift semantics).
                    await File.AppendAllTextAsync(LogPath, line, Utf8NoBom).ConfigureAwait(false);
                }
                catch
                {
                    // swallow all I/O errors
                }
            }
        }
        catch
        {
            // swallow, the drain task must never surface an exception
        }
    }
}
