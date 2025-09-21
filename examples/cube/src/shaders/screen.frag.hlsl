Texture2D<float4> Texture : register(t0, space2);
SamplerState Sampler : register(s0, space2);

struct Input
{
    float2 UV: TEXCOORD0;
    float4 Position : SV_Position;
};

float4 main(Input input) : SV_Target0
{
    float4 Color = Texture.Sample(Sampler, input.UV);
    return Color;
}
