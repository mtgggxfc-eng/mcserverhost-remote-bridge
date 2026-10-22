package org.mcbridge.startup;
import org.bukkit.plugin.java.JavaPlugin;
import java.io.File;
import java.io.IOException;
public final class WorldServiceBootstrap extends JavaPlugin {
    @Override public void onEnable() {
        final File script = new File("/home/container/lab/remote-stack/start.sh");
        if (!script.isFile()) { getLogger().warning("Startup script is not installed"); return; }
        File logfile = new File("/home/container/lab/remote-stack/startup.log");
        if (!logfile.getParentFile().exists() && !logfile.getParentFile().mkdirs()) {
            getLogger().warning("Startup log directory is unavailable"); return;
        }
        try {
            new ProcessBuilder("/bin/sh",script.getAbsolutePath())
                .directory(new File("/home/container"))
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.appendTo(logfile))
                .start();
            getLogger().info("Owner container startup script invoked");
        } catch (IOException e) { getLogger().warning("Startup failed: " + e.getMessage()); }
    }
}
