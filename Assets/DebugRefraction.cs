using UnityEngine;
using SDD.Events;
using System.Security.Cryptography;

public class DebugRefraction : MonoBehaviour, IEventHandler
{
    public Texture3D WorldTexture; // Assign in the inspector
    public Vector3 WorldTextureSize = new Vector3(128, 128, 128); // Define the size of the 3D texture
    public float VoxelRenderDistance = 1000.0f; // Max render distance
    public float air_ratio = 1.0f;
    public float glass_ratio = 1.1f;

    [System.Serializable]
    public struct RayMarchInfo
    {
        public int Complexity; // Number of iterations
        public int BlockID;    // ID of the hit block
        public Vector3 Position; // World-space position of the hit
        public Vector3 Normal;   // Normal at the hit point
        public float Depth;      // Distance to the hit

        public static RayMarchInfo CreateDefault()
        {
            return new RayMarchInfo
            {
                Complexity = 0,
                BlockID = 0,
                Position = Vector3.zero,
                Normal = Vector3.zero,
                Depth = float.MaxValue
            };
        }
    }

    private void OnEnable()
    {
        SubscribeEvents();
    }
    private void OnDisable()
    {
        UnsubscribeEvents();
    }

    public void SubscribeEvents()
    {
        EventManager.Instance.AddListener<WorldGeneratedEvent>(OnWorldGenerated);
    }

    public void UnsubscribeEvents()
    {
        EventManager.Instance.RemoveListener<WorldGeneratedEvent>(OnWorldGenerated);
    }

    private void OnWorldGenerated(WorldGeneratedEvent e)
    {
        this.WorldTexture = e.generator.WorldTexture;
        this.WorldTextureSize = e.generator.Size;
    }

    private bool IsInWorld(Vector3 pos)
    {
        return pos.y < WorldTextureSize.y && pos.y >= 0;
    }

    private Vector3Int VoxelPos(Vector3 pos)
    {
        return new Vector3Int(Mathf.FloorToInt(pos.x), Mathf.FloorToInt(pos.y), Mathf.FloorToInt(pos.z));
    }

    private float DistanceToPlane(Vector3 rayOrigin, Vector3 rayDir, float planeY)
    {
        if (Mathf.Approximately(rayDir.y, 0))
            return -1.0f;

        float t = (planeY - rayOrigin.y) / rayDir.y;

        return t < 0 ? -1.0f : t;
    }

    private (float dstToWorld, float dstInsideWorld) RayWorldHit(Vector3 rayOrigin, Vector3 rayDir)
    {
        float dstTop = DistanceToPlane(rayOrigin, rayDir, WorldTextureSize.y);
        float dstBottom = DistanceToPlane(rayOrigin, rayDir, 0);

        if (IsInWorld(rayOrigin))
            return (0, Mathf.Max(dstTop, dstBottom));

        if (rayOrigin.y > WorldTextureSize.y)
        {
            if (dstTop < 0) return (-1, -1);
            return (dstTop, dstBottom - dstTop);
        }
        else
        {
            if (dstBottom < 0) return (-1, -1);
            return (dstBottom, dstTop - dstBottom);
        }
    }

    private uint SampleWorld(Vector3 pos)
    {
        if (!IsInWorld(pos))
            return 0;

        Vector3Int voxelPos = VoxelPos(pos);
        Color color = WorldTexture.GetPixel(voxelPos.x, voxelPos.y, voxelPos.z);
        if (Mathf.Approximately(color.a, 0))
            return 0;

        return (uint)Mathf.RoundToInt(color.r * 255);
    }

    private Vector3 GetNormal(Vector3 tMax, Vector3 step)
    {
        if (tMax.x < tMax.y && tMax.x < tMax.z)
            return step.x * Vector3.right;
        else if (tMax.y < tMax.z)
            return step.y * Vector3.up;
        else
            return step.z * Vector3.forward;
    }
    Vector3 Refract(Vector3 incident, Vector3 normal, float eta)
    {
        float dotNI = Vector3.Dot(normal, incident);
        float k = 1.0f - eta * eta * (1.0f - dotNI * dotNI);
        if (k < 0.0f)
        {
            return Vector3.zero; // Total internal reflection
        }
        else
        {
            return eta * incident - (eta * dotNI + Mathf.Sqrt(k)) * normal;
        }
    }
    Vector3 Sign(Vector3 v)
    {
        return new Vector3(Mathf.Sign(v.x), Mathf.Sign(v.y), Mathf.Sign(v.z));
    }

    private (Vector3, Vector3, Vector3, Vector3Int) ResetDDA(Vector3 rayDir, Vector3 rayPos)
    {
        Vector3Int voxelIndex = VoxelPos(rayPos);
        Vector3 tMax = Vector3.zero;
        Vector3 tDelta = Vector3.zero;
        Vector3 step = Sign(rayDir);

        for (int i = 0; i < 3; i++)
        {
            if (rayDir[i] == 0)
            {
                tMax[i] = 1e10f;
                tDelta[i] = 1e10f;
            }
            else
            {
                float voxelBoundary = voxelIndex[i] + (step[i] > 0 ? 1 : 0);
                tMax[i] = (voxelBoundary - rayPos[i]) / rayDir[i];
                tDelta[i] = Mathf.Abs(1.0f / rayDir[i]);
            }
        }
        return (tMax, tDelta, step, voxelIndex);
    }

    public RayMarchInfo RayMarchWorld(Vector3 startPos, Vector3 rayDir)
    {
        var (dstToWorld, dstInsideWorld) = RayWorldHit(startPos, rayDir);
        RayMarchInfo result = RayMarchInfo.CreateDefault();

        if (dstInsideWorld <= 0)
        {
            result.Depth = float.MaxValue;
            return result;
        }
        if (dstToWorld > 0)
        {
            startPos += rayDir * dstToWorld;
        }

        // Init DDA
        Vector3 tMax, tDelta, step;
        Vector3Int voxelIndex;
        (tMax, tDelta, step, voxelIndex) = ResetDDA(rayDir, startPos);

        float dstLimit = Mathf.Min(VoxelRenderDistance - dstToWorld, dstInsideWorld);
        float dstTravelled_total = 0;
        float dstTravelled_this_bounce = dstTravelled_total;

        int loopCount = 0;
        int hardLoopLimit = (int)dstLimit * 2;
        int last_medium = 0;
        Vector3 tMax_old = tMax;
        Vector3 rayPos = startPos;
        Vector3 rayPos_old = startPos;
        Vector3 bouncePos = rayPos;

        while (loopCount++ < hardLoopLimit && dstTravelled_total < dstLimit)
        {
            Vector3 normal = -GetNormal(tMax_old, step);

            float epsilon = 0.001f;
            rayPos = bouncePos + (rayDir * dstTravelled_this_bounce) - normal * epsilon;
            uint blockID = SampleWorld(rayPos);

            // Get current medium
            int medium = 0;
            if (blockID == 3)
            {
                medium = 1;
            }

            bool refraction = medium != last_medium;
            if (refraction)
            {
                //if (medium == 0) normal *= -1;

                Gizmos.color = Color.red;
                Gizmos.DrawLine(rayPos, rayPos + normal.normalized);

                // Refract ray
                float eta = last_medium == 0 ? air_ratio / glass_ratio : glass_ratio / air_ratio;
                Vector3 newRayDir = Refract(rayDir.normalized, normal.normalized, eta);
                if (newRayDir.magnitude == 0.0)
                {
                    rayDir = Vector3.Reflect(rayDir, normal); // Total internal reflection
                }
                else
                {
                    rayDir = newRayDir;
                }
                rayDir = rayDir.normalized;

                // Reset DDA
                (tMax, tDelta, step, voxelIndex) = ResetDDA(rayDir, rayPos);

                // Init a new bounce
                bouncePos = rayPos;
                dstTravelled_total += dstTravelled_this_bounce;
                dstTravelled_this_bounce = 0;
            }

            // Draw gizmos
            float gizmoSize = refraction ? 0.15f : 0.1f;
            Gizmos.color = refraction ? Color.blue : Color.green;
            Gizmos.DrawSphere(rayPos, gizmoSize);
            Gizmos.DrawLine(rayPos, rayPos_old);

            last_medium = medium;
            rayPos_old = rayPos;

            // Collide with blocks
            if (blockID > 0 && medium != 1)
            {
                result.BlockID = (int)blockID;
                result.Complexity = loopCount;
                result.Depth = dstToWorld + dstTravelled_total;
                result.Normal = -GetNormal(tMax, step);
                result.Position = rayPos;
                return result;
            }

            if (refraction) continue;

            tMax_old = tMax;
            // Update DDA
            if (tMax.x < tMax.y && tMax.x < tMax.z)
            {
                dstTravelled_this_bounce = tMax.x;
                tMax.x += tDelta.x;
                voxelIndex.x += (int)step.x;
            }
            else if (tMax.y < tMax.z)
            {
                dstTravelled_this_bounce = tMax.y;
                tMax.y += tDelta.y;
                voxelIndex.y += (int)step.y;
            }
            else
            {
                dstTravelled_this_bounce = tMax.z;
                tMax.z += tDelta.z;
                voxelIndex.z += (int)step.z;
            }
        }

        dstTravelled_total += dstTravelled_this_bounce;
        result.Complexity = loopCount;
        result.Depth = float.MaxValue;
        return result;
    }

    void OnDrawGizmos()
    {
        if (WorldTexture == null) return;

        // Debugging visualization
        Vector3 startPos = transform.position;
        Vector3 rayDir = transform.forward;
        RayMarchInfo hitInfo = RayMarchWorld(startPos, rayDir);
    }
}
