Shader "Custom/WorldPostProcess"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        Pass
        {
            ZWrite On
            CGPROGRAM
            #pragma target 3.0
            #pragma vertex vert
            #pragma fragment frag
            #pragma require 2darray
            #include "UnityCG.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
                float3 viewVector : TEXCOORD1;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                // Camera space matches OpenGL convention where cam forward is -z. In unity forward is positive z.
                // (https://docs.unity3d.com/ScriptReference/Camera-cameraToWorldMatrix.html)
                float3 viewVector = mul(unity_CameraInvProjection, float4(v.uv * 2 - 1, 0, -1));
                o.viewVector = mul(unity_CameraToWorld, float4(viewVector, 0));
                return o;
            }

            // G-Buffer
            sampler2D _DepthTexture;
            sampler2D _BlockTexture;
            sampler2D _NormalTexture;
            sampler2D _PositionTexture;

            // World
            sampler2D _MainTex;
            sampler3D _WorldTexture;
            float3 _WorldTextureSize;

            // Textures
            sampler2D _BlockTextureAtlas;
            sampler2D _NoiseTexture;

            // Params
            float3 _CameraPos;
            float3 _PlayerLightPos;
            float3 _PlayerLightDir;
            float _PlayerLightIntensity;
            float _PlayerLightVolumetricIntensity;
            float _PlayerLightRange;
            float _PlayerLightAngle;
            float _VoxelRenderDistance; 
            int _BlocksCount;
            int _DebugToggle;
            int _LightShaftSampleCount;
            float _LightShaftRenderDistance;
            float _LightShaftFadeStart;
            float _LightShaftIntensity;
            float _LightShaftMaximumValue;
            float4 _FogColor;

            // Shadow map
            float3 _LightDir;
            float3 _LightUp;
            float3 _LightRight;

            sampler2D _ShadowMap;
            uint2 _ShadowMapResolution;
            float2 _ShadowMapCoverage;
            float3 _ShadowMapOrigin;

            bool isInWorld(float3 pos)
            {
                return pos.y < _WorldTextureSize.y && pos.y >= 0;
            }
            
            float dstToPlane(float3 rayOrigin, float3 rayDir, float planeY)
            {
                // Check if the plane is parallel to the ray
                if (rayDir.y == 0)
                {
                    return -1.0f;
                }

                float t = (planeY - rayOrigin.y) / rayDir.y;

                // Check if the plane is behind the ray's origin
                if (t < 0)
                {
                    return -1.0f;
                }

                return t;
            }

            // Returns float3 (dist to world, dist inside world, intersection pos)
            float2 rayWorldHit(float3 rayOrigin, float3 rayDir)
            {
                float dstTop = dstToPlane(rayOrigin, rayDir, _WorldTextureSize.y);
                float dstBottom = dstToPlane(rayOrigin, rayDir, 0);

                float dstToWorld;
                float dstInsideWorld;

                // If inside the world
                if (isInWorld(rayOrigin))
                {
                    dstToWorld = 0;
                    // Check if direction is parallel to the planes
                    if (rayDir.y == 0) return float2(dstToWorld, 1e10); 
                    // Return dist inside world
                    return float2(dstToWorld, max(dstTop, dstBottom));
                }

                // If above the world
                if (rayOrigin.y > _WorldTextureSize.y)
                {
                    // Check if looking at world
                    if (dstTop < 0) return float2(-1, -1);

                    dstInsideWorld = dstBottom - dstTop;
                    return float2(dstTop, dstInsideWorld);
                }
                // If under the world
                else
                {
                    // Check if looking at world
                    if (dstBottom < 0) return float2(-1, -1);

                    dstInsideWorld = dstTop - dstBottom;
                    return float2(dstBottom, dstInsideWorld);
                }
            }

            int3 voxelPos(float3 pos)
            {
                return int3(floor(pos.x), floor(pos.y), floor(pos.z));
            }

            float getOutline(float3 pos)
            {
                if (saturate(distance (pos, _CameraPos) / 100) == 1)
                {
                    return 1;
                }

                float x = (pos.x - floor(pos.x));
                x = min(x, 1.0f - x);
                float y = (pos.y - floor(pos.y));
                y = min(y, 1.0f - y);
                float z = (pos.z - floor(pos.z));
                z = min(z, 1.0f - z);

                float edgeThreshold = 2;

                float nearXEdge = x ;
                float nearYEdge = y ;
                float nearZEdge = z ;

                return saturate(0.7 + min(min(nearXEdge + nearYEdge, nearXEdge + nearZEdge), nearYEdge + nearZEdge) * edgeThreshold);
            }

            float3 getNormal(float3 tMax, float3 step)
            {
                // Determine the normal based on the axis of intersection
                if (tMax.x < tMax.y && tMax.x < tMax.z)
                {
                    return step.x * float3(1, 0, 0);
                }
                else if (tMax.y < tMax.z)
                {
                    return step.y * float3(0, 1, 0);
                }
                else
                {
                    return step.z * float3(0, 0, 1);
                }
            }

            float4 getBlockColor(int blockID, float3 pos, float3 normal)
            {
                float2 uv;

                if (normal.y != 0)
                {
                    uv = pos.xz;
                }
                else if (normal.x != 0)
                {
                    uv = pos.zy;
                } 
                else if (normal.z != 0)
                {
                    uv = pos.xy;
                }
                else 
                {
                    return float4(1, 0, 1, 1);
                }

                uv = frac(uv);
                float blockWidth = 1.0 / _BlocksCount; // Width of one block in normalized texture coordinates
                uv.x = uv.x * blockWidth + blockWidth * (blockID - 1); // Offset uv to the correct block
                return tex2D(_BlockTextureAtlas, uv);
            }

            // Sample world using world space coordinates
            uint sampleWorld(float3 pos)
            {
                if (!isInWorld(pos))
                {
                    return 0;
                }
                float4 res = tex3D(_WorldTexture, pos / _WorldTextureSize);
                if (res.a == 0) return 0;

                int blockID = round(res.r * 255); // Scale and round to nearest whole number
                return blockID;
            }

            // Computes ray directions based on a surface normal, used for occlusion
            float3 getSampleDirection(float3 normal, int sampleIndex, int numSamples) {
                float phi = 2.61803398875 * sampleIndex;
                float cosTheta = 1.0 - (float(sampleIndex) / numSamples);
                float sinTheta = sqrt(1.0 - cosTheta * cosTheta);

                // Spherical to Cartesian coordinates
                float x = cos(phi) * sinTheta;
                float y = sin(phi) * sinTheta;
                float z = cosTheta;

                // Align the z-axis with the normal
                float3 up = abs(normal.z) < 0.999 ? float3(0, 0, 1) : float3(0, 1, 0);
                float3 right = normalize(cross(up, normal));
                up = cross(normal, right);

                return normalize(right * x + up * y + normal * z);
            }

            float calculateOcclusion(float3 pos, float3 normal, int numSamples, float radius) 
            {
                
                float occlusion = 0.0;
                for (int i = 0; i < numSamples; ++i) 
                {
                    float3 rayDir = getSampleDirection(normal, i, numSamples);
                    float3 samplePos = pos + rayDir * radius;
                    if (sampleWorld(samplePos) != 0) 
                    { 
                        occlusion += 1.0;
                    }
                }
                return 1.0 - (occlusion / numSamples) * 0.5;
            }

            struct rayMarchInfo
            {
                int complexity;
                int blockID;
                float3 pos;
                float4 color;
                float depth;
                float3 normal;
                float density;
            };

            rayMarchInfo newRayMarchInfo()
            {
                rayMarchInfo info;
                info.complexity = 0;
                info.blockID = 0;
                info.pos = float3(0, 0, 0);
                info.depth = 0;
                info.normal = float3(0, 0, 0);
                info.density = 0;
                return info;
            }

            bool isInShadow_rayMarched(float3 pos, float3 normal, float3 lightDir)
            {
                float3 startPos = pos;
                float3 rayDir = lightDir;
                startPos += normal * 0.002;

                float2 rayWorldInfo = rayWorldHit(startPos, rayDir);
                float dstToWorld = rayWorldInfo.x;
                float dstInsideWorld = rayWorldInfo.y;

                // EXIT EARLY
                if (dstInsideWorld <= 0) 
                {
                    return false;
                }
                if (dstToWorld > 0)
                {
                    startPos = startPos + rayDir * dstToWorld; // Start at intersection point
                }
                int3 voxelIndex = voxelPos(startPos);


                float3 step = sign(rayDir);
                float3 tMax;  // Distance to next voxel boundary
                float3 tMax_old; // Used to get the normals
                float3 tDelta;  // How far we travel to cross a voxel

                // Calculate initial tMax and tDelta for each axis
                for (int i = 0; i < 3; i++)
                { 
                    if (rayDir[i] == 0)
                    {
                        tMax[i] = 1e10;
                        tDelta[i] = 1e10;
                    }
                    else
                    {
                        float voxelBoundary = voxelIndex[i] + (step[i] > 0 ? 1 : 0);
                        tMax[i] = (voxelBoundary - startPos[i]) / rayDir[i]; 
                        tDelta[i] = abs(1.0 / rayDir[i]);
                    }
                }

                float dstLimit = min(_VoxelRenderDistance - dstToWorld, dstInsideWorld);
                float dstTravelled = 0;
                int loopCount = 0;
                int hardLoopLimit = (int) dstLimit * 2; // Hack that prevents convergence caused by precision issues or some dark mathematical magic

                [loop]
                while (loopCount < hardLoopLimit && dstTravelled < dstLimit)
                {
                    // Check the position for a voxel
                    float3 rayPos = startPos + rayDir * (dstTravelled + 0.001);

                    int blockID = sampleWorld(rayPos);
                    
                    // Return the voxel
                    if (blockID != 0 && blockID != 3)
                    {
                        return true;
                    }

                    // Move to the next voxel
                    tMax_old = tMax;
                    if (tMax.x < tMax.y && tMax.x < tMax.z)
                    {
                        dstTravelled = tMax.x;
                        tMax.x += tDelta.x;
                        voxelIndex.x += step.x;
                    }
                    else if (tMax.y < tMax.z)
                    {
                        dstTravelled = tMax.y;
                        tMax.y += tDelta.y;
                        voxelIndex.y += step.y;
                    }
                    else
                    {
                        dstTravelled = tMax.z;
                        tMax.z += tDelta.z;
                        voxelIndex.z += step.z;
                    }
                    loopCount++;
                }
                return false;

            }
            
            // DEPRECATED
            float getLightShaft_old(float3 rayStart, float3 rayDir, float3 lightDir, float depth, float offset)
            {
                    float n = _LightShaftSampleCount;
                    float dstLimit = min(_LightShaftRenderDistance, depth);
                    float dstTravelled = offset;
                    float stepSize = dstLimit / n;
                    
                    float lightScattered = 0;
                    [loop]
                    while (dstTravelled < dstLimit)
                    {
                        float3 rayPos = rayStart + rayDir * dstTravelled;
                        if (!isInShadow_rayMarched(rayPos, float3(0, 0, 0),lightDir))
                        {
                            lightScattered += 0.01 * stepSize / 2;
                        }
                        dstTravelled += stepSize;
                    }
                    return lightScattered;
            }

            // Projects a point onto a plane defined by a normal and a point on the plane
            float3 getIntersectionWithPlane(float3 pos, float3 normal, float3 planePoint)
            {
                float3 v = pos - planePoint;
                float d = dot(v, normal) / dot(normal, normal);
                return pos - d * normal;
            }

            float2 getShadowMapUV(float3 worldPosition)
            {
                // Calculate the intersection of the worldPosition with the plane defined by startPos and lightDir
                float3 intersection = getIntersectionWithPlane(worldPosition, _LightDir, _ShadowMapOrigin);

                // Convert the world position to coordinates on the plane using the right and up vectors
                float2 planeCoords;
                planeCoords.x = dot(intersection - _ShadowMapOrigin, _LightRight);
                planeCoords.y = dot(intersection - _ShadowMapOrigin, _LightUp);

                // Normalize these coordinates based on the shadow map's coverage
                float2 normalizedPosition = float2(
                    (planeCoords.x) / _ShadowMapCoverage.x,
                    (planeCoords.y) / _ShadowMapCoverage.y
                );

                // Convert normalized position to UV coordinates by shifting to [0, 1] range
                float2 uv = normalizedPosition + float2(0.5, 0.5);
                return uv;
            }

            bool isInShadow(float3 pos, float3 normal, float3 lightDir)
            {
                float3 startPos = pos;
                startPos += normal * 0.002;

                float3 shadowMapPos = getIntersectionWithPlane(startPos, lightDir, _ShadowMapOrigin);
                float2 shadowMapUV = getShadowMapUV(startPos);
                float shadowMapDepth = tex2D(_ShadowMap, shadowMapUV).r;

                if (distance(startPos, shadowMapPos) < shadowMapDepth)
                { 
                    return false;
                }
                return true;
            }

            float getPlayerSpotLight(float3 pos, float3 normal)
            {
                float cosAngle = dot(normalize(_PlayerLightDir), normalize(pos - _PlayerLightPos));
                float angle = acos(cosAngle) * (180.0 / 3.14159265);
             
                float dstToPlayer = distance(pos, _PlayerLightPos);
                float light = 1;
                light *= pow(saturate((_PlayerLightAngle - angle) / _PlayerLightAngle), 2);
                return light * (1 - saturate(dstToPlayer / (_PlayerLightRange * 1.2 + 5))) * _PlayerLightIntensity;
            }

            float computeLighting(float3 pos, float3 normal, float3 lightDir, bool useShadowMap)
            {
                float light = dot(lightDir, normal); 
                if (!useShadowMap && isInShadow_rayMarched(pos, normal, lightDir) == true) light = 0; 
                if (useShadowMap && isInShadow(pos, normal, lightDir) == true) light = 0; 

                float playerSpotLight = getPlayerSpotLight(pos, normal);
                light += playerSpotLight;

                float occlusion = calculateOcclusion(pos, normal, 9, 0.3);
                float ambientLight = 0.025 + 0.075 * saturate(pos.y / _WorldTextureSize.y);
                return max(ambientLight, saturate(light)) * occlusion;
            }

            float getLightShaft(float3 rayStart, float3 rayDir, float3 lightDir, float depth, float offset)
            {
                    float n = _LightShaftSampleCount;
                    float dstLimit = min(_LightShaftRenderDistance, depth);
                    float dstTravelled = offset;
                    float stepSize = dstLimit / n;
                    float blendStart = _LightShaftFadeStart * _LightShaftRenderDistance;
                    float lightScattered = 0;

                    [loop]
                    while (dstTravelled < dstLimit)
                    {
                        float blendFactor = 1 - saturate((dstTravelled - blendStart) / (_LightShaftRenderDistance - blendStart));
                        float3 rayPos = rayStart + rayDir * dstTravelled;
                        
                        // Volumetric sun light
                        if (rayPos.y >= _WorldTextureSize.y || isInShadow(rayPos, float3(0, 0, 0), lightDir) == false)
                        {
                            lightScattered += 0.01 * stepSize * blendFactor * _LightShaftIntensity;
                        }

                        // Volumetric spotlight
                        float playerSpotLight = getPlayerSpotLight(rayPos, float3(0, 0, 0));
                        lightScattered += 0.05 * playerSpotLight * blendFactor * stepSize * _PlayerLightVolumetricIntensity;
                        dstTravelled += stepSize;
                    }
                    return clamp(lightScattered, 0, _LightShaftMaximumValue);
            }

            float4 applyFog(float4 color, float fog, float4 fogColor)
            {
                return color * (1 - fog) + fogColor * fog;
            }

            struct DDAInitInfo
            {
                float3 tMax;
                float3 tDelta;
                float3 step;
                int3 voxelIndex;
            };

            DDAInitInfo resetDDA(float3 rayDir, float3 rayPos)
            {
                DDAInitInfo res;
                res.voxelIndex = voxelPos(rayPos);
                res.tMax = float3(0, 0, 0);
                res.tDelta = float3(0, 0, 0);
                res.step = sign(rayDir);

                for (int i = 0; i < 3; i++)
                {
                    if (rayDir[i] == 0)
                    {
                        res.tMax[i] = 1e10f;
                        res.tDelta[i] = 1e10f;
                    }
                    else
                    { 
                        float voxelBoundary = res.voxelIndex[i] + (res.step[i] > 0 ? 1 : 0);
                        res.tMax[i] = (voxelBoundary - rayPos[i]) / rayDir[i];
                        res.tDelta[i] = abs(1.0f / rayDir[i]);
                    }
                }
                return res;
            }

            float3 adjustGlassNormal(float3 pos, float3 normal)
            {
                // Generate UV coordinates directly based on the hardcoded normal direction
                float2 uv = float2(0, 0);

                // Determine the plane based on the cube's axis-aligned normal
                if (normal.y > 0) // Top face
                {
                    uv = pos.xz;
                }
                else if (normal.y < 0) // Bottom face
                {
                    uv = pos.xz;
                }
                else if (normal.x > 0) // Right face
                {
                    uv = pos.zy;
                }
                else if (normal.x < 0) // Left face
                {
                    uv = pos.zy;
                }
                else if (normal.z > 0) // Front face
                {
                    uv = pos.xy;
                }
                else if (normal.z < 0) // Back face
                {
                    uv = pos.xy;
                }

                // Wrap UV coordinates to [0, 1] range
                uv = frac(uv);

                // Generate sine wave perturbation
                float freq = 50.0;
                float waveU = sin(uv.x * freq); // Sine wave along U
                float waveV = cos(uv.y * freq); // Cosine wave along V

                // Hardcoded tangent and bitangent for each face
                float3 tangent = float3(0, 0, 0);
                float3 bitangent = float3(0, 0, 0);

                if (normal.y != 0) // Top/Bottom face
                {
                    tangent = float3(1, 0, 0);  // Tangent along x-axis
                    bitangent = float3(0, 0, 1); // Bitangent along z-axis
                }
                else if (normal.x != 0) // Left/Right face
                {
                    tangent = float3(0, 0, 1);  // Tangent along z-axis
                    bitangent = float3(0, 1, 0); // Bitangent along y-axis
                }
                else if (normal.z != 0) // Front/Back face
                {
                    tangent = float3(1, 0, 0);  // Tangent along x-axis
                    bitangent = float3(0, 1, 0); // Bitangent along y-axis
                }

                // Combine normal perturbations in the local coordinate system
                float perturbation = 0.05;
                float3 perturbedNormal = normal 
                    + waveU * tangent * perturbation 
                    + waveV * bitangent * perturbation;

                // Normalize the final perturbed normal
                perturbedNormal = normalize(perturbedNormal);

                return perturbedNormal;
            }


            // From: 
            // https://blog.demofox.org/2017/01/09/raytracing-reflection-refraction-fresnel-total-internal-reflection-and-beers-law/?utm_source=chatgpt.com
            float FresnelReflectAmount (float n1, float n2, float3 normal, float3 incident, float reflectivity)
            {
                // Schlick aproximation
                float r0 = (n1-n2) / (n1+n2);
                r0 *= r0;
                float cosX = -dot(normal, incident);
                if (n1 > n2)
                {
                    float n = n1/n2;
                    float sinT2 = n*n*(1.0-cosX*cosX);
                    // Total internal reflection
                    if (sinT2 > 1.0)
                        return 1.0;
                    cosX = sqrt(1.0-sinT2);
                }
                float x = 1.0-cosX;
                float ret = r0+(1.0-r0)*x*x*x*x*x;

                // adjust reflect multiplier for object reflectivity
                ret = (reflectivity + (1.0-reflectivity) * ret);
                return ret;
            }


            // Todo: implement beer's law
            // https://blog.demofox.org/2017/01/09/raytracing-reflection-refraction-fresnel-total-internal-reflection-and-beers-law/?utm_source=chatgpt.com
            rayMarchInfo rayMarchWorld(float3 startPos, float3 rayDir, int loopCount = 0)
            {
                rayDir = normalize(rayDir);
                float2 rayWorldInfo = rayWorldHit(startPos, rayDir);
                float dstToWorld = rayWorldInfo.x;
                float dstInsideWorld = rayWorldInfo.y;
                rayMarchInfo res = newRayMarchInfo();

                // EXIT EARLY 
                if (dstInsideWorld <= 0) 
                {
                    res.depth = 1e10;
                    return res;
                }
                if (dstToWorld > 0)
                {
                    startPos += rayDir * dstToWorld; // Start at intersection point
                }

                // Init DDA
                DDAInitInfo dda = resetDDA(rayDir, startPos);

                float dstLimit = min(_VoxelRenderDistance - dstToWorld, dstInsideWorld + 50); // TODO: +50 is a quick fix, the distInsideWorld calculation was a bit off on the edges. Will investigate when I have time.
                float dstTravelled_total = 0;
                float dstTravelled_this_bounce = dstTravelled_total;

                int hardLoopLimit = (int)dstLimit * 2;
                int last_medium = 0;

                float3 tMax_old = dda.tMax;
                float3 rayPos = startPos;
                float3 bouncePos = rayPos;

                [loop]
                while (loopCount++ < hardLoopLimit && dstTravelled_total < dstLimit)
                {
                    float3 normal = -getNormal(tMax_old, dda.step);

                    // Check the position for a voxel
                    float epsilon = 0.0001f;
                    float3 rayPos = bouncePos + (rayDir * dstTravelled_this_bounce) - (normal * epsilon);
                    uint blockID = sampleWorld(rayPos);
                    
                    // Get current medium
                    uint medium = 0;
                    if (blockID == 3) 
                    {
                        medium = 1;
                    }

                    bool refraction = medium != last_medium;
                    bool internal_reflection = false;

                    if (refraction)
                    {
                        normal = adjustGlassNormal(rayPos, normal);

                        float glass_density = 100.2;
                        if (last_medium == 1) res.density += dstTravelled_this_bounce * glass_density;

                        // Init a new bounce
                        bouncePos += rayDir * dstTravelled_this_bounce;
                        dstTravelled_total += dstTravelled_this_bounce;
                        dstTravelled_this_bounce = 0;

                        // Determine IOR
                        float air_ratio = 1.0;
                        float glass_ratio = 1.2;
                        float insideIOR = (last_medium == 0) ? air_ratio : glass_ratio;
                        float outsideIOR = (last_medium == 0) ? glass_ratio : air_ratio;

                        // Compute Fresnel
                        float reflectMultiplier = FresnelReflectAmount(insideIOR, outsideIOR, normal, rayDir, 0.01);
                        float refractMultiplier = 1.0 - reflectMultiplier;

                        // Refract and Reflect
                        float eta = insideIOR / outsideIOR;
                        float3 refractedRay = refract(rayDir, normal, eta);
                        float3 reflectedRay = reflect(rayDir, normal);

                        // Handle Total Internal Reflection (TIR)
                        if (length(refractedRay) == 0.0)
                        {
                            rayDir = reflectedRay;
                        }
                        else
                        {
                            // Mix based on Fresnel
                            rayDir = normalize(reflectedRay * reflectMultiplier + refractedRay * refractMultiplier);
                        }

                        // Reset DDA
                        dda = resetDDA(rayDir, bouncePos);
                    }
                    if (!internal_reflection)
                    {
                        last_medium = medium;
                    }

                    // Return the voxel
                    if (blockID > 0 && medium != 1)
                    {
                        res.blockID = blockID;
                        res.complexity = loopCount;
                        res.depth = dstToWorld + dstTravelled_total; // CAREFUL : Depth not really valid since it was refracted
                        res.normal = normal;
                        res.pos = rayPos;
                        return res;
                    }

                    if (refraction) continue;
                    tMax_old = dda.tMax;

                    // Move to the next voxel
                    if (dda.tMax.x < dda.tMax.y && dda.tMax.x < dda.tMax.z) // Move along x axis
                    {
                        dstTravelled_this_bounce = dda.tMax.x;
                        dda.tMax.x += dda.tDelta.x;
                        dda.voxelIndex.x += dda.step.x;
                    }
                    else if (dda.tMax.y < dda.tMax.z) // Move along y axis
                    {
                        dstTravelled_this_bounce = dda.tMax.y;
                        dda.tMax.y += dda.tDelta.y;
                        dda.voxelIndex.y += dda.step.y;
                    }
                    else
                    {
                        dstTravelled_this_bounce = dda.tMax.z; // Move along z axis
                        dda.tMax.z += dda.tDelta.z;
                        dda.voxelIndex.z += dda.step.z;
                    }
                }

                dstTravelled_total += dstTravelled_this_bounce;
                res.complexity = loopCount;
                res.depth = 1e10;
                return res;
            }

            float4 frag (v2f i) : SV_Target
            {
                // Create ray
                float3 rayPos = _CameraPos;
                float viewLength = length(i.viewVector);
                float3 rayDir = i.viewVector.xyz;
                float3 lightDir = _WorldSpaceLightPos0;

                // Sample background
                float4 backgroundColor = tex2D(_MainTex, i.uv);

                // Read G-Buffer map
                float3 pos = tex2D(_PositionTexture, i.uv).xyz;
                float depth = tex2D(_DepthTexture, i.uv).r;
                float3 normal = tex2D(_NormalTexture, i.uv);
                uint block = round(tex2D(_BlockTexture, i.uv).r);
                bool isBackground = block == 0;
                float4 worldColor = getBlockColor(block, pos, normal);// * getOutline(pos);
                float refraction_transmittance = 1;

                // Handle refractions
                if (block == 3)
                {
                    rayMarchInfo refraction = rayMarchWorld(rayPos, rayDir);
                    pos = refraction.pos;
                    depth = refraction.depth;
                    normal = refraction.normal;
                    block = refraction.blockID;
                    isBackground = block == 0;

                    if (block != 0)
                    {
                        worldColor = getBlockColor(refraction.blockID, refraction.pos, refraction.normal);
                        // Apply beer's law.
                        refraction_transmittance = saturate(exp(-refraction.density * 0.00025));
                    }
                }

                // Compute fog
                float fog = saturate(depth / 5000);
                //float4 fogColor = saturate(dot(lightDir, float3(0, 1, 0)));
                float4 fogColor = _FogColor;

                // Compute lighting
                float offset = tex2D(_NoiseTexture, i.uv/1) * 2;
                float lightShaft = getLightShaft(rayPos, rayDir, lightDir, depth, offset);
                float lightShaftTimeMultiplier = saturate(dot(float3(0, 1, 0), lightDir)) * 2;
                lightShaft *= lightShaftTimeMultiplier;
                if (isBackground)
                {
                    // Render object with lighting
                    if (depth < 10000)
                    {
                        float3 objectPos = rayPos + rayDir * depth;
                        float3 light = 1;
                        if (isInShadow_rayMarched(objectPos, float3(0, 0, 0), lightDir))
                        {
                            light = 0.2;
                        }
                        return applyFog(float4(backgroundColor.rgb * light + lightShaft, 1), fog, fogColor);
                    }
                    // Render skybox
                    else
                    {
                        // Reduce fog in the sky
                        return applyFog(backgroundColor + lightShaft, fog * (1 - saturate(dot(rayDir, float3(0, 1, 0)) + 0.5)), fogColor);
                    }
                }

                float lightIntensity = computeLighting(pos, normal, lightDir, false);
                worldColor = float4(worldColor.rgb * lightIntensity, worldColor.a);
                
                float4 glassColor = float4(52.9, 80.8, 92.2, 0) / 100.0;
                worldColor = lerp(glassColor, worldColor, refraction_transmittance);
                return applyFog(float4(worldColor + lightShaft), fog, fogColor);
            }

            ENDCG
        }
    }
}
