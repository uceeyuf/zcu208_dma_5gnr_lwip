function [rxFrame, A] = img_align(rx, ref, Nfr)
%IMG_ALIGN  Align a capture to the frame start with a non-coherent, block-wise cross-correlation that is immune to
%   residual frequency offset.
%
%   [rxFrame, A] = img_align(rx, ref, Nfr)
%
% rx  : captured complex baseband (one full playback cycle, length >= Nfr; on the board 2^21 = frame + zero gap)
% ref : ideal transmitted frame (200 MS/s, Nfr samples)
% Nfr : frame length
%
% Why not one coherent whole-frame cross-correlation: the DAC and ADC NCOs are not co-sourced, leaving a residual
% frequency offset of a few hundred Hz. Over a 10-ms frame, 180 Hz is 1.8 turns, which smears or splits a coherent
% correlation peak. The reference is therefore cut into K blocks of 2^16 samples (0.33 ms, < 0.4 rad of rotation
% inside a block); each block is correlated on its own and the magnitudes are shifted and added (non-coherent).
%
% A: off (integer sample offset), pkMed (peak / median: real data >> 1, noise ~5), nBlk (blocks used)
rx  = rx(:);
ref = ref(:);
if nargin < 3 || isempty(Nfr), Nfr = numel(ref); end
assert(numel(rx) >= Nfr, 'img_align:short', 'rx has %d samples, needs >= %d', numel(rx), Nfr);

rxLoop = [rx; rx(1:Nfr)];
NL = numel(rxLoop);
Rl = fft(rxLoop);

Lb = 2^16;
K  = 4;
starts = round(linspace(0, Nfr-Lb, K));
% use blocks with enough energy (slot 0 of the frame carries only the SSB)
e = arrayfun(@(o) sum(abs(ref(o+(1:Lb))).^2), starts);
starts = starts(e > 0.2*max(e));

acc = zeros(NL, 1);
for ob = starts
    v = zeros(NL, 1);
    v(1:Lb) = ref(ob + (1:Lb));
    cb = ifft(Rl .* conj(fft(v)));
    acc = acc + circshift(abs(cb), -ob);      % peak at ob+off, shifted back to off and added non-coherently
end

cand = acc(1:numel(rx));
[pk, i0] = max(cand);
A.off   = i0 - 1;
A.pkMed = pk / median(cand);
A.nBlk  = numel(starts);
rxFrame = rxLoop(i0 : i0+Nfr-1);
end
