using SDD.Events;
using System;
using UnityEngine;

public class BlockPlacer : MonoBehaviour, IEventHandler
{
    public int blockID;
    public bool placeBlock;
    public Texture3D WorldTexture { get; private set; }
    public bool WorldGenerated { get; private set; }
    private Vector3Int WorldTextureSize;
    private int framesSinceGeneration;

    #region Events
    public void SubscribeEvents()
    {
        EventManager.Instance.AddListener<WorldGeneratedEvent>(RetrieveWorldGenerator);
    }
    public void UnsubscribeEvents()
    {
        EventManager.Instance.RemoveListener<WorldGeneratedEvent>(RetrieveWorldGenerator);
    }

    public void RetrieveWorldGenerator(WorldGeneratedEvent e)
    {
        WorldTexture = e.generator.WorldTexture;
        WorldTextureSize.x = WorldTexture.width;
        WorldTextureSize.y = WorldTexture.height;
        WorldTextureSize.z = WorldTexture.depth;
        WorldGenerated = true;
    }
    #endregion

    private void OnEnable()
    {
        SubscribeEvents();
    }

    private void OnDisable()
    {
        UnsubscribeEvents();
    }

    #region edit
    private Vector3Int GetGridPos(Vector3 pos)
    {
        Vector3Int gridPos = new Vector3Int((int)Math.Floor(pos.x), (int)Math.Floor(pos.y), (int)Math.Floor(pos.z));
        gridPos.x = gridPos.x % WorldTextureSize.x;
        if (gridPos.x < 0) gridPos.x += WorldTextureSize.x;
        gridPos.y = Math.Clamp(gridPos.y, 0, WorldTextureSize.y);
        gridPos.z = gridPos.z % WorldTextureSize.z;
        if (gridPos.z < 0) gridPos.z += WorldTextureSize.z;
        return gridPos;
    }
    public bool RemoveBlock(Vector3 position)
    {
        Vector3Int gridPos = GetGridPos(position);
        float pixel = WorldTexture.GetPixel(gridPos.x, gridPos.y, gridPos.z).r;
        if (pixel <= 0)
        {
            return false;
        }
        WorldTexture.SetPixel(gridPos.x, gridPos.y, gridPos.z, Color.clear);
        return true;
    }

    public void ApplyChanges()
    {
        WorldTexture.Apply();
    }

    public void SetBlock(Vector3 position, int blockID)
    {
        Vector3Int gridPos = GetGridPos(position);
        WorldTexture.SetPixel(gridPos.x, gridPos.y, gridPos.z, new Color(blockID / 255.0f, 0, 0, 0));
    }
    #endregion

    private void Update()
    {
        if (WorldGenerated)
        {
            framesSinceGeneration++;
        }

        if (placeBlock && framesSinceGeneration > 10)
        {
            SetBlock(transform.position, blockID);
            ApplyChanges();
            placeBlock = false;
        }
    }
}
