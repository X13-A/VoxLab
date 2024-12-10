using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using SDD.Events;

public class SceneLoadedEvent : SDD.Events.Event
{
    public int scene;
}

#region Rendering Events
public class ToggleFlashlightVolumetricsEvent : SDD.Events.Event
{
    public bool value;
}

public class ScreenResolutionChangedEvent : SDD.Events.Event
{
    public int width;
    public int height;
    public int gBufferWidth;
    public int gBufferHeight;
}

public class GBufferScaleSliderEvent : SDD.Events.Event
{
    public float value;
}

public class ScreenManagerReadyEvent : SDD.Events.Event
{
    public int width;
    public int height;
    public int gBufferWidth;
    public int gBufferHeight;
}

// Called every frame before the custom post processing starts
public class StartPostProcessingEvent : SDD.Events.Event
{
}

public class GBufferReadyForInitEvent : SDD.Events.Event
{
}

public class GBufferInitializedEvent : SDD.Events.Event
{
    public GBuffer gbuffer;
}

public class ShadowMapInitializedEvent : SDD.Events.Event
{
    public ShadowMap shadowMap;
}

#endregion

#region Generation Events
public class WorldGeneratedEvent : SDD.Events.Event
{
    public WorldGenerator generator;
}

public class GiveWorldGeneratorEvent : SDD.Events.Event
{
    public WorldGenerator generator;
}

public class WorldConfigChangedEvent : SDD.Events.Event
{
}
#endregion
public class SetCloudDensityEvent : SDD.Events.Event
{
    public float eValue; // from 0 to 1 : 0 = black, 1 = full light
}

public class SetCloudCoverageEvent : SDD.Events.Event
{
    public float eValue; // from 0 to 1 : 0 = no clouds, 1 = full clouds
}
public class RequestWorldGeneratorEvent : SDD.Events.Event
{
}
