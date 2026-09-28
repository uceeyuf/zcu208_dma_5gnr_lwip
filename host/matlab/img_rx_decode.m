function D = img_rx_decode(rxFrame, M, opts)
%IMG_RX_DECODE  Recover the image from a captured 200 MS/s baseband frame (PDSCH -> DL-SCH -> bits -> pixels).
%
%   D = img_rx_decode(rxFrame, M)
%   D = img_rx_decode(rxFrame, M, struct('markErrors', true))
%
% rxFrame : complex baseband column at 200 MS/s, aligned to the frame start (img_align); >= M.Nfr samples
% M       : metadata from img_make_waveform
%
% Receiver (the practical receive loop of the NR PDSCH Throughput example, applied to a capture):
%   200 -> 122.88 MS/s -> fine timing -> data-aided CFO correction -> nrOFDMDemodulate
%   -> per slot: DM-RS channel estimate (nrChannelEstimate) -> nrExtractResources -> nrEqualizeMMSE
%      -> nrPDSCHDecode -> nrDLSCHDecoder (LDPC + CRC)
%   -> transport blocks concatenated -> 16-byte header removed -> image
%
% opts (all optional):
%   fo          'aided'  CFO: 'aided' = linear phase fit against the known transmitted waveform, 'none'
%   markErrors  false    paint the pixels of slots whose CRC failed mid-grey (shows which band was lost)
%   maxIter     12       maximum LDPC iterations
%   avgWin      []       nrChannelEstimate AveragingWindow [F T]; empty = toolbox automatic setting
%   verbose     true
%
% D: img rxBytes blkerr bler slotBER preBER postBER evmSlot evm cfoHz toffset hdrOK psnr pixErrRate
%    preBER  = pre-decoding hard-decision BER of the coded bits; postBER = payload BER after LDPC decoding
if nargin < 3, opts = struct(); end
def = struct('fo', 'aided', 'markErrors', false, 'maxIter', 12, 'avgWin', [], 'verbose', true);
fn = fieldnames(def);
for k = 1:numel(fn)
    if ~isfield(opts, fn{k}), opts.(fn{k}) = def.(fn{k}); end
end
vb = @(varargin) fprintf(varargin{:});
if ~opts.verbose, vb = @(varargin) []; end

rxFrame = rxFrame(:);
assert(numel(rxFrame) >= M.Nfr, 'img_rx_decode:short', 'rxFrame has %d samples, needs %d', numel(rxFrame), M.Nfr);
rxFrame = rxFrame(1:M.Nfr);

%% ---- 1. back to the native NR rate ----
rxN = resample(rxFrame, 384, 625);               % 200 -> 122.88 MS/s
txN = double(M.txNative(:));
N0  = numel(txN);
if numel(rxN) > N0, rxN = rxN(1:N0); elseif numel(rxN) < N0, rxN(end+1:N0) = 0; end

%% ---- 2. fine timing (+-8 native samples; the 200-MS/s integer alignment leaves < 1 native sample) ----
seg = 1:min(200000, N0);
best = 0;  bestc = -inf;
for d = -8:8
    r = circshift(rxN, -d);
    c = abs(txN(seg)' * r(seg));
    if c > bestc, bestc = c;  best = d; end
end
rxN = circshift(rxN, -best);
D.toffset = best;

%% ---- 3. CFO (data-aided: block-wise complex gain against the known waveform -> linear phase fit) ----
% The DAC and ADC NCOs are not co-sourced; an uncorrected residual offset rotates later slots over a 10-ms frame.
cfoHz = 0;
if strcmpi(opts.fo, 'aided')
    Nb = 8192;  nb = floor(N0/Nb);
    rb = reshape(rxN(1:nb*Nb), Nb, nb);
    tb = reshape(txN(1:nb*Nb), Nb, nb);
    num = sum(rb .* conj(tb), 1).';              % least-squares complex gain per block (numerator)
    den = sum(abs(tb).^2, 1).';
    ok  = den > 0.05*median(den);                % drop nearly empty blocks (slot 0 carries only the SSB)
    g   = num(ok) ./ den(ok);
    t   = ((find(ok)-1)*Nb + Nb/2) / M.Fs0;
    ph  = unwrap(angle(g));
    W   = den(ok) / max(den);                    % energy weighting
    A   = [t(:) ones(numel(t),1)];
    pf  = (A' * (W.*A)) \ (A' * (W.*ph));
    cfoHz = pf(1) / (2*pi);
    n = (0:N0-1).';
    rxN = rxN .* exp(-1j*2*pi*cfoHz/M.Fs0 * n);
end
D.cfoHz = cfoHz;
vb('receiver: fine timing %+d native samples, CFO %+.1f Hz\n', best, cfoHz);

%% ---- 4. OFDM demodulation (whole frame) ----
carrier = M.carrier;
carrier.NSlot = 0;
rxGrid = nrOFDMDemodulate(carrier, rxN, 'SampleRate', M.Fs0);
L = carrier.SymbolsPerSlot;

%% ---- 5. PDSCH + DL-SCH decoding, slot by slot ----
res  = M.res;
nS   = numel(res);
dec  = nrDLSCHDecoder('MultipleHARQProcesses', false, 'TargetCodeRate', M.TargetCodeRate, ...
    'LDPCDecodingAlgorithm', 'Normalized min-sum', 'MaximumLDPCIterationCount', opts.maxIter);

bitsOut = zeros(M.capBits, 1);
blkerr  = false(1, nS);
slotBER = nan(1, nS);
evmSlot = nan(1, nS);
slotBitRange = zeros(nS, 2);
pos = 0;
allEq = cell(1, nS);
for k = 1:nS
    r   = res(k);
    tbn = double(r.TransportBlockSize);
    slotBitRange(k,:) = [pos+1, pos+tbn];

    gslot = rxGrid(:, r.NSlot*L + (1:L), :);
    cecArgs = {};
    if ~isempty(opts.avgWin), cecArgs = {'AveragingWindow', opts.avgWin}; end
    [H, nVar] = nrChannelEstimate(gslot, r.DMRSIndices, r.DMRSSymbols, ...
        'CDMLengths', M.CDMLengths, 'CyclicPrefix', carrier.CyclicPrefix, cecArgs{:});
    [pdschRx, pdschH] = nrExtractResources(r.ChannelIndices, gslot, H);
    if ~any(abs(pdschH), 'all')
        blkerr(k) = true;  pos = pos + tbn;  continue;
    end
    [eq, csi] = nrEqualizeMMSE(pdschRx, pdschH, nVar);
    allEq{k} = eq;

    carrier.NSlot = r.NSlot;
    [llr, rxSym] = nrPDSCHDecode(carrier, M.pdsch, eq, nVar);

    % CSI weighting (as in the NR PDSCH Throughput example)
    csid = nrLayerDemap(csi);
    for cw = 1:numel(llr)
        Qm = numel(llr{cw}) / numel(rxSym{cw});
        csicw = reshape(repmat(csid{cw}.', Qm, 1), [], 1);
        llr{cw} = llr{cw} .* csicw;
    end

    % pre-decoding BER (hard decision on the LLRs vs the transmitted codeword; LLR < 0 -> bit 1)
    if isfield(r, 'Codeword') && ~isempty(r.Codeword)
        cwTx = double(r.Codeword(:));
        hb   = double(llr{1} < 0);
        n    = min(numel(hb), numel(cwTx));
        slotBER(k) = mean(hb(1:n) ~= cwTx(1:n));
    end
    % slot EVM (equalized constellation vs the transmitted PDSCH symbols)
    if isfield(r, 'ChannelSymbols') && numel(r.ChannelSymbols) == numel(eq)
        ref = double(r.ChannelSymbols(:));
        e   = eq(:);
        a   = (ref' * e) / (ref' * ref);         % remove the residual complex gain
        evmSlot(k) = 100 * norm(e - a*ref) / norm(a*ref);
    end

    reset(dec);
    dec.TransportBlockLength = tbn;
    [trblk, err] = dec(llr, M.pdsch.Modulation, M.pdsch.NumLayers, double(r.RV));
    if iscell(trblk), trblk = trblk{1}; end
    blkerr(k) = any(err);
    bitsOut(pos + (1:tbn)) = double(trblk(:));
    pos = pos + tbn;
end
assert(pos == M.capBits, 'img_rx_decode:bits', '%d bits reassembled, expected %d', pos, M.capBits);

e = cat(1, allEq{~cellfun(@isempty, allEq)});
D.eqSym   = e(1:10:end);                         % decimated equalized constellation (for plots)
D.blkerr  = blkerr;
D.slotBER = slotBER;
D.evmSlot = evmSlot;
D.evm     = mean(evmSlot(~isnan(evmSlot)));
D.bler    = mean(blkerr);
D.preBER  = mean(slotBER(~isnan(slotBER)));
vb('decoder: %d/%d slots pass CRC, pre-decoding BER %.2e, equalized EVM %.2f %%\n', nnz(~blkerr), nS, D.preBER, D.evm);

%% ---- 6. bits -> image ----
payBits = bitsOut(1:M.nPayBits);
D.postBER = mean(payBits(:) ~= double(M.srcBits(:)));
bytes   = bits2bytes(payBits);
D.rxBytes = bytes;
hdr = bytes(1:M.HDR);
D.hdrOK = isequal(char(hdr(1:4).'), 'IMG1');
R_ = M.imgSize(1);  C_ = M.imgSize(2);  Ch_ = M.imgSize(3);
if D.hdrOK
    R_ = double(typecast(uint8(hdr(5:6)), 'uint16'));
    C_ = double(typecast(uint8(hdr(7:8)), 'uint16'));
    Ch_ = double(hdr(9));
    if R_*C_*Ch_ ~= numel(bytes) - M.HDR       % damaged header: fall back to the metadata size
        R_ = M.imgSize(1);  C_ = M.imgSize(2);  Ch_ = M.imgSize(3);
        D.hdrOK = false;
    end
end
pix = bytes(M.HDR + (1:R_*C_*Ch_));
if opts.markErrors                              % paint the pixels of CRC-failed slots mid-grey
    bad = false(M.capBits, 1);
    for k = find(blkerr)
        bad(slotBitRange(k,1):slotBitRange(k,2)) = true;
    end
    badPay  = bad(1:M.nPayBits);
    badByte = any(reshape(badPay, 8, []), 1).';
    bp = badByte(M.HDR + (1:R_*C_*Ch_));
    pix(bp) = uint8(128);
end
D.img = permute(reshape(pix, Ch_, C_, R_), [3 2 1]);   % undo the row-major serialisation

D.psnr = NaN;  D.pixErrRate = NaN;
if isequal(size(D.img), size(M.srcImage))
    e = double(D.img) - double(M.srcImage);
    mse = mean(e(:).^2);
    if mse == 0, D.psnr = Inf; else, D.psnr = 10*log10(255^2/mse); end
    D.pixErrRate = mean(e(:) ~= 0);
end
vb('image: %dx%dx%d, header %s, payload BER %.2e, PSNR %.1f dB\n', R_, C_, Ch_, ternary(D.hdrOK, 'OK', 'damaged'), D.postBER, D.psnr);
end

function b = bits2bytes(bits)
bits = double(bits(:));
n = floor(numel(bits)/8);
b = uint8(sum(reshape(bits(1:8*n), 8, n).' .* (2.^(7:-1:0)), 2));
end

function o = ternary(c, a, b)
if c, o = a; else, o = b; end
end
