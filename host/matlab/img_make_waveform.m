function M = img_make_waveform(imgFile, waveFormat, opts)
%IMG_MAKE_WAVEFORM  Put an image into the PDSCH transport blocks of a 5G NR FRC downlink frame and return the
%   200 MS/s waveform to play on the board, with the metadata img_rx_decode needs.
%
%   M = img_make_waveform('peppers.png', '64QAM')
%   M = img_make_waveform(img, 'QPSK', struct('maxDim', 256))
%
% Method (R2024a 5G Toolbox): hNRReferenceWaveformGenerator builds the DL-FRC-FR1-* reference waveform; after
% makeConfigWritable, Config.PDSCH{1}.DataSource is switched from 'PN9-ITU' to the image bit vector, and
% nrWaveformGenerator fills the DL-SCH transport blocks of consecutive PDSCH slots with it, in order. The waveform is
% generated at 122.88 MS/s (273 PRB at 30 kHz) and resampled (625/384) to 200 MS/s = 2,000,000 samples per 10 ms.
%
% Payload per 10-ms frame (19 PDSCH slots, 100 MHz / 30 kHz FDD): QPSK 41.6 kB | 64QAM 313.8 kB | 256QAM 427.7 kB.
%
% opts (all optional):
%   fit     'resize'   image larger than the frame: 'resize' scales it down to fit, 'error' stops
%   maxDim  []         scale the longer image side to this many pixels first
%   gray    false      convert to grayscale
%
% M.wave200 is the 200 MS/s complex waveform (column); the other fields are for img_rx_decode.
if nargin < 2 || isempty(waveFormat), waveFormat = '64QAM'; end
if nargin < 3, opts = struct(); end
def = struct('fit', 'resize', 'maxDim', [], 'gray', false);
fn = fieldnames(def);
for k = 1:numel(fn)
    if ~isfield(opts, fn{k}), opts.(fn{k}) = def.(fn{k}); end
end

rcTab = struct('QPSK', "DL-FRC-FR1-QPSK", 'x64QAM', "DL-FRC-FR1-64QAM", ...
               'x256QAM', "DL-FRC-FR1-256QAM", 'x1024QAM', "DL-FRC-FR1-1024QAM");
key = waveFormat;
if ~isvarname(key), key = ['x' key]; end
assert(isfield(rcTab, key), 'img_make_waveform:fmt', 'unsupported format %s (QPSK/64QAM/256QAM/1024QAM)', waveFormat);
rc = rcTab.(key);

%% ---- 1. reference configuration and capacity (one run with the default PN9 to get the TBS per slot) ----
bw = "100MHz";  scs = "30kHz";  dm = "FDD";
gen = hNRReferenceWaveformGenerator(rc, bw, scs, dm);
[~, ~, probe] = gen.generateWaveform();
res0 = probe.WaveformResources.PDSCH(1).Resources;
tbs  = double([res0.TransportBlockSize]);        % transport block size of each PDSCH slot
capBits  = sum(tbs);
capBytes = floor(capBits/8);
fprintf('[%s] %d PDSCH slots, TBS %d bit/slot, payload %d bit = %.1f kB per 10-ms frame\n', ...
    rc, numel(tbs), tbs(1), capBits, capBytes/1024);

%% ---- 2. image -> bytes ----
if ischar(imgFile) || isstring(imgFile)
    img = imread(char(imgFile));  srcName = char(imgFile);
else
    img = imgFile;  srcName = '<in-memory>';
end
if ~isa(img, 'uint8'), img = im2uint8(img); end
if opts.gray && size(img,3) == 3, img = rgb2gray(img); end
if ~isempty(opts.maxDim)
    sc = opts.maxDim / max(size(img,1), size(img,2));
    if sc < 1, img = imresize(img, sc); end
end
HDR = 16;                                        % 16-byte header
if HDR + numel(img) > capBytes
    switch opts.fit
        case 'resize'
            sc = sqrt((capBytes - HDR) / numel(img)) * 0.999;
            img = imresize(img, sc);
            while HDR + numel(img) > capBytes, img = imresize(img, 0.99); end
            fprintf('image larger than the frame, scaled to %dx%dx%d (%.1f kB)\n', ...
                size(img,1), size(img,2), size(img,3), numel(img)/1024);
        otherwise
            error('img_make_waveform:tooBig', 'image %.1f kB exceeds the %s frame capacity %.1f kB', ...
                (HDR+numel(img))/1024, waveFormat, capBytes/1024);
    end
end
[R_, C_, Ch_] = size(img);
% row-major serialisation: consecutive bytes = one image row, so one failed slot = one horizontal band
pix = reshape(permute(img, [3 2 1]), [], 1);
hdr = zeros(HDR, 1, 'uint8');
hdr(1:4)   = uint8('IMG1');
hdr(5:6)   = typecast(uint16(R_), 'uint8');
hdr(7:8)   = typecast(uint16(C_), 'uint8');
hdr(9)     = uint8(Ch_);
hdr(10)    = uint8(0);                           % 0 = raw uint8 pixels
hdr(11:14) = typecast(uint32(numel(pix)), 'uint8');
payload  = [hdr; pix];
srcBits  = bytes2bits(payload);
nPay     = numel(srcBits);
dataBits = [srcBits; zeros(capBits - nPay, 1)];  % zero-fill the frame (the decoder truncates at nPay)
fprintf('payload %d bytes (%dx%dx%d pixels + %d header), %.1f %% of the frame\n', ...
    numel(payload), R_, C_, Ch_, HDR, 100*numel(payload)/capBytes);

%% ---- 3. regenerate the waveform with the image bits ----
gen = gen.makeConfigWritable();
cfg = gen.Config;
cfg.PDSCH{1}.DataSource = int8(dataBits);
gen.Config = cfg;
[wave, ~, winfo] = gen.generateWaveform();
res = winfo.WaveformResources.PDSCH(1).Resources;
Fs0 = winfo.ResourceGrids(1).Info.SampleRate;    % 122.88e6
assert(abs(Fs0 - 122.88e6) < 1, 'img_make_waveform:fs', 'native rate %.4f MHz, expected 122.88', Fs0/1e6);

% self-check: the generator consumed dataBits in order
tb1 = double(res(1).TransportBlock(:));
assert(isequal(tb1, dataBits(1:numel(tb1))), 'img_make_waveform:ds', 'DataSource order differs from the expected one');

%% ---- 4. resample to the board rate ----
Fs = 200e6;
w200 = resample(wave(:,1), 625, 384);            % 122.88 -> 200 MS/s, 1228800 -> 2000000
assert(numel(w200) == 2e6, 'img_make_waveform:len', '%d samples after resampling, expected 2000000', numel(w200));

%% ---- 5. metadata ----
keep = {'NSlot','TransportBlockSize','RV','Codeword','ChannelIndices', ...
        'ChannelSymbols','DMRSIndices','DMRSSymbols'};
resS = struct();
for k = 1:numel(res)
    for f = keep, resS(k).(f{1}) = res(k).(f{1}); end
end
p = cfg.PDSCH{1};
pdsch = nrPDSCHConfig;   % nrWavegenPDSCHConfig is not a subclass of nrPDSCHConfig: copy property by property
for f = {'Modulation','NumLayers','MappingType','SymbolAllocation','PRBSet','NID','RNTI', ...
         'VRBToPRBInterleaving','VRBBundleSize','ReservedPRB','ReservedRE','DMRS', ...
         'EnablePTRS','PTRS'}
    if isprop(p, f{1}) && isprop(pdsch, f{1}), pdsch.(f{1}) = p.(f{1}); end
end
pdsch.NSizeBWP  = cfg.BandwidthParts{1}.NSizeBWP;
pdsch.NStartBWP = cfg.BandwidthParts{1}.NStartBWP;
carrier = nrCarrierConfig('NCellID', cfg.NCellID, 'SubcarrierSpacing', 30, ...
    'CyclicPrefix', 'normal', 'NSizeGrid', cfg.SCSCarriers{1}.NSizeGrid, ...
    'NStartGrid', cfg.SCSCarriers{1}.NStartGrid, 'NSlot', 0, 'NFrame', 0);

M = struct();
M.rc = rc;  M.bw = bw;  M.scs = scs;  M.dm = dm;  M.waveFormat = waveFormat;
M.carrier = carrier;  M.pdsch = pdsch;  M.res = resS;
M.TargetCodeRate = p.TargetCodeRate;
M.CDMLengths = winfo.WaveformResources.PDSCH(1).CDMLengths;
M.tbs = tbs;  M.capBits = capBits;  M.capBytes = capBytes;
M.srcBits = logical(srcBits);  M.nPayBits = nPay;  M.HDR = HDR;
M.imgSize = [R_ C_ Ch_];  M.srcImage = img;  M.srcFile = srcName;
M.Fs0 = Fs0;  M.Fs = Fs;  M.Nfr = numel(w200);
M.txNative = single(wave(:,1));                  % ideal native-rate waveform (fine sync and CFO in the decoder)
M.wave200 = w200;
end

function bits = bytes2bits(b)
% MSB first
b = uint8(b(:));
bits = double(reshape(bitget(repmat(b,1,8), repmat(8:-1:1, numel(b), 1)).', [], 1));
end
