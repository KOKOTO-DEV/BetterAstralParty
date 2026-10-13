using System.Threading;
internal static class InertProcess
{
    private static int Main(string[] args)
    {
        int milliseconds;
        if (args.Length != 1 || !int.TryParse(args[0], out milliseconds) || milliseconds < 0 || milliseconds > 5000) return 2;
        Thread.Sleep(milliseconds);
        return 0;
    }
}
