cbuffer UniformBlock : register(b0, space3)
{
    float Time;
    uint Effect;
};

Texture2D<float4> Texture : register(t0, space2);
SamplerState Sampler : register(s0, space2);

struct Input
{
    float2 UV: TEXCOORD0;
    float4 Position : SV_Position;
};

float4 main(Input input) : SV_Target0
{
    float2 offset = float2(0, 0);

    if (Effect == 1) {
        offset.y = sin(input.UV.x * 100.0 + Time) * 0.01;
    } else if (Effect == 2) {
        offset.x = sin(input.UV.y * 100.0 + Time) * 0.01;
    } else if (Effect == 3) {
        offset.y = sin(input.UV.x * 100.0 + Time) * 0.01;
        offset.x = sin(input.UV.y * 100.0 + Time) * 0.01;
    }

    float4 Color = Texture.Sample(Sampler, input.UV + offset);
    return Color;
}
