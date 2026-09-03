using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace XMLMacker.Shared;

/// <summary>
/// Single-instance arbitration + file-path forwarding, the Windows replacement for the macOS
/// <c>application(_:openFile:)</c> event. The first launch owns a named <see cref="Mutex"/> and runs
/// a named-pipe server; a second launch forwards its file-path argument to the running instance and
/// exits.
///
/// <para><see cref="PathReceived"/> is raised on a background (pipe) thread, subscribers must marshal
/// to the UI thread themselves (e.g. via <c>Dispatcher.InvokeAsync</c>).</para>
/// </summary>
public sealed class SingleInstance : IDisposable
{
    private const string MutexName = "xml-macker-SingleInstance";
    private const string PipeName = "xml-macker-SingleInstance-Pipe";
    private const int ConnectTimeoutMs = 1500;

    private readonly Mutex _mutex;
    private readonly CancellationTokenSource _cts = new();
    private Task? _serverTask;
    private bool _disposed;

    /// <summary>Raised (on a pipe thread) when a second instance forwards a file path.</summary>
    public event Action<string>? PathReceived;

    /// <summary>True if this process is the first/owning instance.</summary>
    public bool IsFirstInstance { get; }

    public SingleInstance()
    {
        _mutex = new Mutex(initiallyOwned: true, name: MutexName, createdNew: out bool createdNew);
        IsFirstInstance = createdNew;
    }

    /// <summary>
    /// If this is the first instance, starts the named-pipe listener loop. No-op for secondary
    /// instances.
    /// </summary>
    public void StartServer()
    {
        if (!IsFirstInstance || _serverTask is not null) return;
        _serverTask = Task.Run(() => ServerLoop(_cts.Token));
    }

    private async Task ServerLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                using var server = new NamedPipeServerStream(
                    PipeName, PipeDirection.In, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous);

                await server.WaitForConnectionAsync(token).ConfigureAwait(false);

                using var reader = new StreamReader(server, Encoding.UTF8);
                string? path = await reader.ReadToEndAsync().ConfigureAwait(false);
                if (!string.IsNullOrWhiteSpace(path))
                    PathReceived?.Invoke(path.Trim());
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch
            {
                // Ignore a broken connection and keep listening.
            }
        }
    }

    /// <summary>
    /// Called by a SECOND instance to hand its file path to the running one. Returns true on success.
    /// </summary>
    public static bool SignalFirstInstance(string path)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            client.Connect(ConnectTimeoutMs);
            using var writer = new StreamWriter(client, new UTF8Encoding(false));
            writer.Write(path ?? string.Empty);
            writer.Flush();
            return true;
        }
        catch
        {
            return false;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        try { _cts.Cancel(); } catch { /* ignore */ }
        try { _serverTask?.Wait(500); } catch { /* ignore */ }
        _cts.Dispose();

        try
        {
            if (IsFirstInstance) _mutex.ReleaseMutex();
        }
        catch
        {
            // Mutex may already be released/abandoned.
        }
        _mutex.Dispose();
    }
}
