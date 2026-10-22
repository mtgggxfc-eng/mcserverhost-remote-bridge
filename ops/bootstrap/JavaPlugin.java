package org.bukkit.plugin.java;
import java.util.logging.Logger;
public abstract class JavaPlugin {
    public Logger getLogger(){ return Logger.getLogger(getClass().getName()); }
    public void onEnable(){}
}
