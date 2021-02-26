
#import "GLTFAssetReader.h"

#define CGLTF_IMPLEMENTATION
#import "cgltf.h"

@interface GLTFUniqueNameGenerator : NSObject
- (NSString *)nextUniqueNameWithPrefix:(NSString *)prefix;
@end

@interface GLTFUniqueNameGenerator ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *countsForPrefixes;
@end

@implementation GLTFUniqueNameGenerator

- (instancetype)init {
    if (self = [super init]) {
        _countsForPrefixes = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)nextUniqueNameWithPrefix:(NSString *)prefix {
    NSNumber *existingCount = self.countsForPrefixes[prefix];
    if (existingCount) {
        self.countsForPrefixes[prefix] = @(existingCount.integerValue + 1);
        return [NSString stringWithFormat:@"%@%@", prefix, existingCount];
    }
    self.countsForPrefixes[prefix] = @(1);
    return [NSString stringWithFormat:@"%@%d", prefix, 1];
}

@end

static GLTFComponentType GLTFComponentTypeForType(cgltf_component_type type) {
    return (GLTFComponentType)type;
}

static GLTFValueDimension GLTFDimensionForAccessorType(cgltf_type type) {
    return (GLTFValueDimension)type;
}

static GLTFAlphaMode GLTFAlphaModeFromMode(cgltf_alpha_mode mode) {
    return (GLTFAlphaMode)mode;
}

static GLTFPrimitiveType GLTFPrimitiveTypeFromType(cgltf_primitive_type type) {
    return (GLTFPrimitiveType)type;
}

static GLTFInterpolationMode GLTFInterpolationModeForType(cgltf_interpolation_type type) {
    return (GLTFInterpolationMode)type;
}

static NSString *GLTFTargetPathForPath(cgltf_animation_path_type path) {
    switch (path) {
        case cgltf_animation_path_type_rotation:
            return GLTFAnimationPathRotation;
        case cgltf_animation_path_type_scale:
            return GLTFAnimationPathScale;
        case cgltf_animation_path_type_translation:
            return GLTFAnimationPathTranslation;
        case cgltf_animation_path_type_weights:
            return GLTFAnimationPathWeights;
        default:
            return @"";
    }
}

static GLTFLightType GLTFLightTypeForType(cgltf_light_type type) {
    return (GLTFLightType)type;
}

@interface GLTFAssetReader () {
    cgltf_data *gltf;
}
@property (class, nonatomic, readonly) dispatch_queue_t loaderQueue;
@property (nonatomic, nullable, strong) NSURL *assetURL;
@property (nonatomic, strong) GLTFAsset *asset;
@property (nonatomic, strong) GLTFUniqueNameGenerator *nameGenerator;
@end

static dispatch_queue_t _loaderQueue;

@implementation GLTFAssetReader

+ (dispatch_queue_t)loaderQueue {
    if (_loaderQueue == nil) {
        _loaderQueue = dispatch_queue_create("com.metalbyexample.gltfkit2.asset-loader", DISPATCH_QUEUE_CONCURRENT);
    }
    return _loaderQueue;
}

+ (void)loadAssetWithURL:(NSURL *)url
                 options:(NSDictionary<GLTFAssetLoadingOption, id> *)options
                 handler:(nullable GLTFAssetLoadingHandler)handler
{
    dispatch_async(self.loaderQueue, ^{
        GLTFAssetReader *loader = [[GLTFAssetReader alloc] init];
        [loader syncLoadAssetWithURL:url data:nil options:options handler:handler];
    });
}

+ (void)loadAssetWithData:(NSData *)data
                  options:(NSDictionary<GLTFAssetLoadingOption, id> *)options
                  handler:(nullable GLTFAssetLoadingHandler)handler
{
    dispatch_async(self.loaderQueue, ^{
        GLTFAssetReader *loader = [[GLTFAssetReader alloc] init];
        [loader syncLoadAssetWithURL:nil data:data options:options handler:handler];
    });
}

- (instancetype)init {
    if (self = [super init]) {
        _nameGenerator = [GLTFUniqueNameGenerator new];
    }
    return self;
}

- (void)syncLoadAssetWithURL:(NSURL * _Nullable)assetURL
                        data:(NSData * _Nullable)data
                     options:(NSDictionary<GLTFAssetLoadingOption, id> *)options
                     handler:(nullable GLTFAssetLoadingHandler)handler
{
    self.assetURL = assetURL;

    BOOL stop = NO;
    NSData *internalData = data ?: [NSData dataWithContentsOfURL:assetURL];
    if (internalData == nil) {
        handler(1.0, GLTFAssetStatusError, nil, nil, &stop);
        return;
    }
    
    cgltf_options parseOptions = {0};
    cgltf_result result = cgltf_parse(&parseOptions, internalData.bytes, internalData.length, &gltf);
    
    if (result != cgltf_result_success) {
        handler(1.0, GLTFAssetStatusError, nil, nil, &stop);
    } else {        
        result = cgltf_load_buffers(&parseOptions, gltf, assetURL.fileSystemRepresentation);
        if (result != cgltf_result_success) {
            handler(1.0, GLTFAssetStatusError, nil, nil, &stop);
        } else {
            [self convertAsset];
            handler(1.0, GLTFAssetStatusComplete, self.asset, nil, &stop);
        }
    }
    
    cgltf_free(gltf);
}

- (NSArray *)convertBuffers {
    NSMutableArray *buffers = [NSMutableArray arrayWithCapacity:gltf->buffers_count];
    for (int i = 0; i < gltf->buffers_count; ++i) {
        cgltf_buffer *b = gltf->buffers + i;
        GLTFBuffer *buffer = nil;
        if (b->data) {
            buffer = [[GLTFBuffer alloc] initWithData:[NSData dataWithBytes:b->data length:b->size]];
        } else {
            buffer = [[GLTFBuffer alloc] initWithLength:b->size];
        }
        // TODO: buffers can have user-defined names, but cgltf doesn't currently support this (v1.9)
        buffer.name = [self.nameGenerator nextUniqueNameWithPrefix:@"Buffer"];
        [buffers addObject:buffer];
    }
    return buffers;
}

- (NSArray *)convertBufferViews {
    NSMutableArray *bufferViews = [NSMutableArray arrayWithCapacity:gltf->buffer_views_count];
    for (int i = 0; i < gltf->buffer_views_count; ++i) {
        cgltf_buffer_view *bv = gltf->buffer_views + i;
        size_t bufferIndex = bv->buffer - gltf->buffers;
        GLTFBufferView *bufferView = [[GLTFBufferView alloc] initWithBuffer:self.asset.buffers[bufferIndex]
                                                                     length:bv->size
                                                                     offset:bv->offset
                                                                     stride:bv->stride];
        // TODO: buffer views can have user-defined names, but cgltf doesn't currently support this (v1.9)
        bufferView.name = [self.nameGenerator nextUniqueNameWithPrefix:@"BufferView"];
        [bufferViews addObject:bufferView];
    }
    return bufferViews;
}

- (NSArray *)convertAccessors
{
    NSMutableArray *accessors = [NSMutableArray arrayWithCapacity:gltf->accessors_count];
    for (int i = 0; i < gltf->accessors_count; ++i) {
        cgltf_accessor *a = gltf->accessors + i;
        GLTFBufferView *bufferView = nil;
        if (a->buffer_view) {
            size_t bufferViewIndex = a->buffer_view - gltf->buffer_views;
            bufferView = self.asset.bufferViews[bufferViewIndex];
        }
        GLTFAccessor *accessor = [[GLTFAccessor alloc] initWithBufferView:bufferView
                                                                   offset:a->offset
                                                            componentType:GLTFComponentTypeForType(a->component_type)
                                                                dimension:GLTFDimensionForAccessorType(a->type)
                                                                    count:a->count
                                                               normalized:a->normalized];
        
        size_t componentCount = GLTFComponentCountForDimension(accessor.dimension);
        if (a->has_min) {
            NSMutableArray *minArray = [NSMutableArray array];
            for (int i = 0; i < componentCount; ++i) {
                [minArray addObject:@(a->min[i])];
            }
            accessor.minValues = minArray;
        }
        if (a->has_max) {
            NSMutableArray *maxArray = [NSMutableArray array];
            for (int i = 0; i < componentCount; ++i) {
                [maxArray addObject:@(a->max[i])];
            }
            accessor.maxValues = maxArray;
        }
        // TODO: Sparse
        accessor.name = a->name ? [NSString stringWithUTF8String:a->name]
                                : [self.nameGenerator nextUniqueNameWithPrefix:@"Accessor"];
        [accessors addObject:accessor];
    }
    return accessors;
}

- (NSArray *)convertTextureSamplers
{
    NSMutableArray *textureSamplers = [NSMutableArray arrayWithCapacity:gltf->samplers_count];
    for (int i = 0; i < gltf->samplers_count; ++i) {
        cgltf_sampler *s = gltf->samplers + i;
        GLTFTextureSampler *sampler = [GLTFTextureSampler new];
        sampler.magFilter = s->mag_filter;
        sampler.minMipFilter = s->min_filter;
        sampler.wrapS = s->wrap_s;
        sampler.wrapT = s->wrap_t;
        // TODO: samplers can have user-defined names, but this isn't currently supported by cgltf (v1.9)
        sampler.name = [self.nameGenerator nextUniqueNameWithPrefix:@"Sampler"];
        [textureSamplers addObject:sampler];
    }
    return textureSamplers;
}

- (NSArray *)convertImages
{
    NSMutableArray *images = [NSMutableArray arrayWithCapacity:gltf->images_count];
    for (int i = 0; i < gltf->images_count; ++i) {
        cgltf_image *img = gltf->images + i;
        GLTFImage *image = nil;
        if (img->buffer_view) {
            size_t bufferViewIndex = img->buffer_view - gltf->buffer_views;
            GLTFBufferView *bufferView = self.asset.bufferViews[bufferViewIndex];
            NSString *mime = [NSString stringWithUTF8String:img->mime_type ? img->mime_type : "image/image"];
            image = [[GLTFImage alloc] initWithBufferView:bufferView mimeType:mime];
        } else {
            assert(img->uri);
            NSURL *baseURI = [self.asset.url URLByDeletingLastPathComponent];
            NSURL *imageURI = [baseURI URLByAppendingPathComponent:[NSString stringWithUTF8String:img->uri]];
            image = [[GLTFImage alloc] initWithURI:imageURI];
        }
        image.name = img->name ? [NSString stringWithUTF8String:img->name]
                               : [self.nameGenerator nextUniqueNameWithPrefix:@"Image"];
        [images addObject:image];
    }
    return images;
}

- (NSArray *)convertTextures
{
    NSMutableArray *textures = [NSMutableArray arrayWithCapacity:gltf->textures_count];
    for (int i = 0; i < gltf->textures_count; ++i) {
        cgltf_texture *t = gltf->textures + i;
        GLTFImage *image = nil;
        GLTFTextureSampler *sampler = nil;
        if (t->image) {
            size_t imageIndex = t->image - gltf->images;
            image = self.asset.images[imageIndex];
        }
        if (t->sampler) {
            size_t samplerIndex = t->sampler - gltf->samplers;
            sampler = self.asset.samplers[samplerIndex];
        }
        GLTFTexture *texture = [[GLTFTexture alloc] initWithSource:image];
        texture.sampler = sampler;
        texture.name = t->name ? [NSString stringWithUTF8String:t->name]
                               : [self.nameGenerator nextUniqueNameWithPrefix:@"Texture"];
        [textures addObject:texture];
    }
    return textures;
}

- (GLTFTextureParams *)textureParamsFromTextureView:(cgltf_texture_view *)tv {
    size_t textureIndex = tv->texture - gltf->textures;
    GLTFTextureParams *params = [GLTFTextureParams new];
    params.texture = self.asset.textures[textureIndex];
    params.scale = tv->scale;
    params.texCoord = tv->texcoord;
    if (tv->has_transform) {
        GLTFTextureTransform *transform = [GLTFTextureTransform new];
        transform.offset = (simd_float2){ tv->transform.offset[0], tv->transform.offset[1] };
        transform.rotation = tv->transform.rotation;
        transform.scale = (simd_float2){ tv->transform.scale[0], tv->transform.scale[1] };
        transform.texCoord = tv->transform.texcoord;
        params.transform = transform;
    }
    return params;
}

- (NSArray *)convertMaterials
{
    NSMutableArray *materials = [NSMutableArray arrayWithCapacity:gltf->materials_count];
    for (int i = 0; i < gltf->materials_count; ++i) {
        cgltf_material *m = gltf->materials + i;
        GLTFMaterial *material = [GLTFMaterial new];
        if (m->normal_texture.texture) {
            material.normalTexture = [self textureParamsFromTextureView:&m->normal_texture];
        }
        if (m->occlusion_texture.texture) {
            material.occlusionTexture = [self textureParamsFromTextureView:&m->occlusion_texture];
        }
        if (m->emissive_texture.texture) {
            material.emissiveTexture = [self textureParamsFromTextureView:&m->emissive_texture];
        }
        float *emissive = m->emissive_factor;
        material.emissiveFactor = (simd_float3){ emissive[0], emissive[1], emissive[2] };
        material.alphaMode = GLTFAlphaModeFromMode(m->alpha_mode);
        material.alphaCutoff = m->alpha_cutoff;
        material.doubleSided = (BOOL)m->double_sided;
        if (m->has_pbr_metallic_roughness) {
            GLTFPBRMetallicRoughnessParams *pbr = [GLTFPBRMetallicRoughnessParams new];
            float *baseColor = m->pbr_metallic_roughness.base_color_factor;
            pbr.baseColorFactor = (simd_float4){ baseColor[0], baseColor[1], baseColor[2], baseColor[3] };
            if (m->pbr_metallic_roughness.base_color_texture.texture) {
                pbr.baseColorTexture = [self textureParamsFromTextureView:&m->pbr_metallic_roughness.base_color_texture];
            }
            pbr.metallicFactor = m->pbr_metallic_roughness.metallic_factor;
            pbr.roughnessFactor = m->pbr_metallic_roughness.roughness_factor;
            if (m->pbr_metallic_roughness.metallic_roughness_texture.texture) {
                pbr.metallicRoughnessTexture = [self textureParamsFromTextureView:&m->pbr_metallic_roughness.metallic_roughness_texture];
            }
            material.metallicRoughness = pbr;
        }
        if (m->has_clearcoat) {
            GLTFClearcoatParams *clearcoat = [GLTFClearcoatParams new];
            clearcoat.clearcoatFactor = m->clearcoat.clearcoat_factor;
            if (m->clearcoat.clearcoat_texture.texture) {
                clearcoat.clearcoatTexture = [self textureParamsFromTextureView:&m->clearcoat.clearcoat_texture];
            }
            clearcoat.clearcoatRoughnessFactor = m->clearcoat.clearcoat_roughness_factor;
            if (m->clearcoat.clearcoat_roughness_texture.texture) {
                clearcoat.clearcoatRoughnessTexture = [self textureParamsFromTextureView:&m->clearcoat.clearcoat_roughness_texture];
            }
            if (m->clearcoat.clearcoat_normal_texture.texture) {
                clearcoat.clearcoatNormalTexture = [self textureParamsFromTextureView:&m->clearcoat.clearcoat_normal_texture];
            }
            material.clearcoat = clearcoat;
        }
        if (m->unlit) {
            material.unlit = YES;
        }
        // TODO: PBR specular-glossiness?
        // TODO: sheen
        material.name = m->name ? [NSString stringWithUTF8String:m->name]
                                : [self.nameGenerator nextUniqueNameWithPrefix:@"Material"];
        [materials addObject:material];
    }
    return materials;
}

- (NSArray *)convertMeshes
{
    NSMutableArray *meshes = [NSMutableArray arrayWithCapacity:gltf->meshes_count];
    for (int i = 0; i < gltf->meshes_count; ++i) {
        cgltf_mesh *m = gltf->meshes + i;
        GLTFMesh *mesh = [GLTFMesh new];
        NSMutableArray *primitives = [NSMutableArray array];
        for (int j = 0; j < m->primitives_count; ++j) {
            cgltf_primitive *p = m->primitives + j;
            GLTFPrimitiveType type = GLTFPrimitiveTypeFromType(p->type);
            NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
            for (int k = 0; k < p->attributes_count; ++k) {
                cgltf_attribute *a = p->attributes + k;
                NSString *attrName = [NSString stringWithUTF8String:a->name];
                size_t attrIndex = a->data - gltf->accessors;
                GLTFAccessor *attrAccessor = self.asset.accessors[attrIndex];
                attributes[attrName] = attrAccessor;
            }
            GLTFPrimitive *primitive = nil;
            if (p->indices) {
                size_t accessorIndex = p->indices - gltf->accessors;
                GLTFAccessor *indices = self.asset.accessors[accessorIndex];
                primitive = [[GLTFPrimitive alloc] initWithPrimitiveType:type attributes:attributes indices:indices];
            } else {
                primitive = [[GLTFPrimitive alloc] initWithPrimitiveType:type attributes:attributes];
            }
            if (p->material) {
                size_t materialIndex = p->material - gltf->materials;
                primitive.material = self.asset.materials[materialIndex];
            }
            [primitives addObject:primitive];
        }
        mesh.primitives = primitives;
        // TODO: morph targets
        mesh.name = m->name ? [NSString stringWithUTF8String:m->name]
                            : [self.nameGenerator nextUniqueNameWithPrefix:@"Mesh"];
        [meshes addObject:mesh];
    }
    return meshes;
}

- (NSArray *)convertCameras
{
    NSMutableArray *cameras = [NSMutableArray array];
    for (int i = 0; i < gltf->cameras_count; ++i) {
        cgltf_camera *c = gltf->cameras + i;
        GLTFCamera *camera = nil;
        if (c->type == cgltf_camera_type_orthographic) {
            GLTFOrthographicProjectionParams *params = [[GLTFOrthographicProjectionParams alloc] init];
            params.xMag = c->data.orthographic.xmag;
            params.yMag = c->data.orthographic.ymag;
            camera = [[GLTFCamera alloc] initWithOrthographicProjection:params];
            camera.zNear = c->data.orthographic.znear;
            camera.zFar = c->data.orthographic.zfar;
        } else if (c->type == cgltf_camera_type_perspective) {
            GLTFPerspectiveProjectionParams *params = [[GLTFPerspectiveProjectionParams alloc] init];
            params.yFOV = c->data.perspective.yfov;
            params.aspectRatio = c->data.perspective.aspect_ratio;
            camera = [[GLTFCamera alloc] initWithPerspectiveProjection:params];
            camera.zNear = c->data.perspective.znear;
            camera.zFar = c->data.perspective.zfar;
        } else {
            camera = [[GLTFCamera alloc] init]; // Got an invalid camera, so just make a dummy to occupy the slot
        }
        camera.name = c->name ? [NSString stringWithUTF8String:c->name]
                              : [self.nameGenerator nextUniqueNameWithPrefix:@"Camera"];
        [cameras addObject:camera];
    }
    return cameras;
}

- (NSArray *)convertLights
{
    NSMutableArray *lights = [NSMutableArray array];
    for (int i = 0; i < gltf->lights_count; ++i) {
        cgltf_light *l = gltf->lights + i;
        GLTFLight *light = [[GLTFLight alloc] initWithType:GLTFLightTypeForType(l->type)];
        light.color = (simd_float3){ l->color[0], l->color[1], l->color[2] };
        light.intensity = l->intensity;
        light.range = l->range;
        if (l->type == cgltf_light_type_spot) {
            light.innerConeAngle = l->spot_inner_cone_angle;
            light.outerConeAngle = l->spot_outer_cone_angle;
        }
        [lights addObject:light];
    }
    return lights;
}

- (NSArray *)convertNodes
{
    NSMutableArray *nodes = [NSMutableArray array];
    for (int i = 0; i < gltf->nodes_count; ++i) {
        cgltf_node *n = gltf->nodes + i;
        GLTFNode *node = [[GLTFNode alloc] init];
        if (n->camera) {
            size_t cameraIndex = n->camera - gltf->cameras;
            node.camera = self.asset.cameras[cameraIndex];
        }
        if (n->light) {
            size_t lightIndex = n->light - gltf->lights;
            node.light = self.asset.lights[lightIndex];
        }
        if (n->mesh) {
            size_t meshIndex = n->mesh - gltf->meshes;
            node.mesh = self.asset.meshes[meshIndex];
        }
        if (n->has_matrix) {
            simd_float4x4 transform;
            memcpy(&transform, n->matrix, sizeof(float) * 16);
            node.matrix = transform;
            // TODO: decompose transform to T,R,S
        } else {
            if (n->has_translation) {
                node.translation = simd_make_float3(n->translation[0], n->translation[1], n->translation[2]);
            }
            if (n->has_scale) {
                node.scale = simd_make_float3(n->scale[0], n->scale[1], n->scale[2]);
            }
            if (n->has_rotation) {
                node.rotation = simd_quaternion(n->rotation[0], n->rotation[1], n->rotation[2], n->rotation[3]);
            }
            float m[16];
            cgltf_node_transform_local(n, &m[0]);
            simd_float4x4 transform;
            memcpy(&transform, m, sizeof(float) * 16);
            node.matrix = transform;
        }
        // TODO: morph target weights
        node.name = n->name ? [NSString stringWithUTF8String:n->name]
                            : [self.nameGenerator nextUniqueNameWithPrefix:@"Node"];
        [nodes addObject:node];
    }
    for (int i = 0; i < gltf->nodes_count; ++i) {
        cgltf_node *n = gltf->nodes + i;
        GLTFNode *node = nodes[i];
        if (n->children_count > 0) {
            NSMutableArray *children = [NSMutableArray arrayWithCapacity:n->children_count];
            for (int j = 0; j < n->children_count; ++j) {
                size_t childIndex = n->children[j] - gltf->nodes;
                GLTFNode *child = nodes[childIndex];
                [children addObject:child];
            }
            node.childNodes = children; // Automatically creates inverse child->parent reference
        }
    }
    return nodes;
}

- (NSArray *)convertSkins
{
    NSMutableArray *skins = [NSMutableArray array];
    for (int i = 0; i < gltf->skins_count; ++i) {
        cgltf_skin *s = gltf->skins + i;
        NSMutableArray *joints = [NSMutableArray arrayWithCapacity:s->joints_count];
        for (int j = 0; j < s->joints_count; ++j) {
            size_t jointIndex = s->joints[j] - gltf->nodes;
            GLTFNode *joint = self.asset.nodes[jointIndex];
            [joints addObject:joint];
        }
        GLTFSkin *skin = [[GLTFSkin alloc] initWithJoints:joints];
        if (s->inverse_bind_matrices) {
            size_t ibmIndex = s->inverse_bind_matrices - gltf->accessors;
            GLTFAccessor *ibms = self.asset.accessors[ibmIndex];
            skin.inverseBindMatrices = ibms;
        }
        if (s->skeleton) {
            size_t skeletonIndex = s->skeleton - gltf->nodes;
            GLTFNode *skeletonRoot = self.asset.nodes[skeletonIndex];
            skin.skeleton = skeletonRoot;
        }
        skin.name = s->name ? [NSString stringWithUTF8String:s->name]
                            : [self.nameGenerator nextUniqueNameWithPrefix:@"Skin"];
        [skins addObject:skin];
    }
    return skins;
}

- (NSArray *)convertAnimations
{
    NSMutableArray *animations = [NSMutableArray array];
    for (int i = 0; i < gltf->animations_count; ++i) {
        cgltf_animation *a = gltf->animations + i;
        NSMutableArray<GLTFAnimationSampler *> *samplers = [NSMutableArray arrayWithCapacity:a->samplers_count];
        for (int j = 0; j < a->samplers_count; ++j) {
            cgltf_animation_sampler *s = a->samplers + j;
            size_t inputIndex = s->input - gltf->accessors;
            GLTFAccessor *input = self.asset.accessors[inputIndex];
            size_t outputIndex = s->output - gltf->accessors;
            GLTFAccessor *output = self.asset.accessors[outputIndex];
            GLTFAnimationSampler *sampler = [[GLTFAnimationSampler alloc] initWithInput:input output:output];
            sampler.interpolationMode = GLTFInterpolationModeForType(s->interpolation);
            [samplers addObject:sampler];
        }
        NSMutableArray<GLTFAnimationChannel *> *channels = [NSMutableArray arrayWithCapacity:a->channels_count];
        for (int j = 0; j < a->channels_count; ++j) {
            cgltf_animation_channel *c = a->channels + j;
            NSString *targetPath = GLTFTargetPathForPath(c->target_path);
            GLTFAnimationTarget *target = [[GLTFAnimationTarget alloc] initWithPath:targetPath];
            if (c->target_node) {
                size_t targetIndex = c->target_node - gltf->nodes;
                GLTFNode *targetNode = self.asset.nodes[targetIndex];
                target.node = targetNode;
            }
            size_t samplerIndex = c->sampler - a->samplers;
            GLTFAnimationSampler *sampler = samplers[samplerIndex];
            GLTFAnimationChannel *channel = [[GLTFAnimationChannel alloc] initWithTarget:target sampler:sampler];
            [channels addObject:channel];
        }
        GLTFAnimation *animation = [[GLTFAnimation alloc] initWithChannels:channels samplers:samplers];
        animation.name = a->name ? [NSString stringWithUTF8String:a->name]
                                 : [self.nameGenerator nextUniqueNameWithPrefix:@"Animation"];
        [animations addObject:animation];
    }
    return animations;
}

- (NSArray *)convertScenes
{
    NSMutableArray *scenes = [NSMutableArray array];
    for (int i = 0; i < gltf->scenes_count; ++i) {
        cgltf_scene *s = gltf->scenes + i;
        GLTFScene *scene = [GLTFScene new];
        NSMutableArray *rootNodes = [NSMutableArray arrayWithCapacity:s->nodes_count];
        for (int j = 0; j < s->nodes_count; ++j) {
            size_t nodeIndex = s->nodes[j] - gltf->nodes;
            GLTFNode *node = self.asset.nodes[nodeIndex];
            [rootNodes addObject:node];
        }
        scene.nodes = rootNodes;
        scene.name = s->name ? [NSString stringWithUTF8String:s->name]
                             : [self.nameGenerator nextUniqueNameWithPrefix:@"Scene"];
        [scenes addObject:scene];
    }
    return scenes;
}

- (void)convertAsset {
    self.asset = [GLTFAsset new];
    self.asset.url = self.assetURL;
    cgltf_asset *meta = &gltf->asset;
    if (meta->copyright) {
        self.asset.copyright = [NSString stringWithUTF8String:meta->copyright];
    }
    if (meta->generator) {
        self.asset.generator = [NSString stringWithUTF8String:meta->generator];
    }
    if (meta->min_version) {
        self.asset.minVersion = [NSString stringWithUTF8String:meta->min_version];
    }
    if (meta->version) {
        self.asset.version = [NSString stringWithUTF8String:meta->version];
    }
    // TODO: extensions meta
    // TODO: extensions/extras
    self.asset.buffers = [self convertBuffers];
    self.asset.bufferViews = [self convertBufferViews];
    self.asset.accessors = [self convertAccessors];
    self.asset.samplers = [self convertTextureSamplers];
    self.asset.images = [self convertImages];
    self.asset.textures = [self convertTextures];
    self.asset.materials = [self convertMaterials];
    self.asset.meshes = [self convertMeshes];
    self.asset.cameras = [self convertCameras];
    self.asset.lights = [self convertLights];
    self.asset.nodes = [self convertNodes];
    self.asset.skins = [self convertSkins];
    
    for (int i = 0; i < gltf->nodes_count; ++i) {
        cgltf_node *n = gltf->nodes + i;
        GLTFNode *node = self.asset.nodes[i];
        if (n->skin) {
            size_t skinIndex = n->skin - gltf->skins;
            node.skin = self.asset.skins[skinIndex];
        }
    }
    
    self.asset.animations = [self convertAnimations];
    self.asset.scenes = [self convertScenes];
    if (gltf->scene) {
        size_t sceneIndex = gltf->scene - gltf->scenes;
        GLTFScene *scene = self.asset.scenes[sceneIndex];
        self.asset.defaultScene = scene;
    } else {
        self.asset.defaultScene = self.asset.scenes.firstObject;
    }
}

@end
