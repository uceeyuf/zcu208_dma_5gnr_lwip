function [rx, info] = play_capture_eth(z, opts)
% PLAY_CAPTURE_ETH  Play one complex baseband cycle through the board and capture the ADC stream over Ethernet.
%
%   [rx, info] = play_capture_eth(z)
%   [rx, info] = play_capture_eth(z, opts)
%
%   z      complex column, |z| <= 1, ONE DMA cycle at 200 MS/s (the DAC replays it cyclically). Its length in bytes
%          (4 bytes per complex sample) must be a multiple of 4 KB.
%   opts   struct, all fields optional:
%            ip, port     lwIP server (default 192.168.1.10 : 7000)
%            tx_addr      DDR address of the DAC buffer   (default 0x40001000)
%            cap_addr     DDR address of the ADC buffer   (default 0x10001000)
%            capture_KB   capture size in KB             (default 16384 = 4,194,304 complex samples at 200 MS/s)
%            settle_s     wait after dacPlay before the capture (default 3 s)
%   rx     complex column at 200 MS/s, ADC full scale = 1
%   info   byte counts, transfer times, ADC peak, and a canary flag (true = the ADC DMA did not write the buffer)
%
%   Memory formats of this design (DAC Tile 228 ch0 / ADC Tile 226 ch0, 200-MHz fabric clock):
%     DAC buffer  int16 I0 Q0 I1 Q1 ...              (plain time-ordered interleave)
%     ADC buffer  int16 I0 Q0 I1 Q1 ...              (plain time-ordered interleave, one I/Q pair per clock)
if nargin < 2, opts = struct(); end
g = @(f, d) getf(opts, f, d);
ip = g('ip', '192.168.1.10'); port = g('port', 7000);
tx_addr = g('tx_addr', hex2dec('40001000')); cap_addr = g('cap_addr', hex2dec('10001000'));
capture_KB = g('capture_KB', 16384); settle_s = g('settle_s', 3); fs = 2^15;

z = z(:); assert(max(abs(z)) <= 1 + 1e-9, 'play_capture_eth: |z| must be <= 1 (got %.3f)', max(abs(z)));
sig = zeros(2*numel(z), 1, 'int16');
sig(1:2:end) = int16(round(real(z)*(fs-1))); sig(2:2:end) = int16(round(imag(z)*(fs-1)));
play_KB = numel(sig)*2/1024; assert(mod(play_KB, 4) == 0, 'play size must be a multiple of 4 KB (got %g KB)', play_KB);

E = [];
for tries = 1:10
    try, E = RfsocEth(ip, port, 60); if E.ping(), break; end, catch, E = []; pause(1); end
end
assert(~isempty(E), 'play_capture_eth:ethDown', 'no lwIP server at %s:%d', ip, port);
E.cmd('dacStop'); pause(0.5);
tw = tic; E.write(tx_addr, typecast(sig(:).', 'uint8')); t_up = toc(tw);
canary = repmat(typecast(uint32(hex2dec('DEADDEAD')), 'uint8'), 1, 16); E.write(cap_addr, canary);
E.cmd(sprintf('dacPlay %d', play_KB)); pause(settle_s);
E.cmd(sprintf('adcCapture %d', capture_KB)); pause(5);
tr = tic; b = E.read(cap_addr, capture_KB*1024); t_down = toc(tr);
delete(E);

canary_hit = isequal(uint8(b(1:64)), canary(1:64));
Y = double(typecast(uint8(b(:).'), 'int16')).';
rx = (Y(1:2:end) + 1i*Y(2:2:end)) / fs;
info = struct('play_KB', play_KB, 'capture_KB', capture_KB, 't_up_s', t_up, 't_down_s', t_down, ...
              'canary_untouched', canary_hit, 'n_rx', numel(rx), 'adc_peak_dBFS', 20*log10(max(abs([real(rx); imag(rx)]))));
if canary_hit, warning('play_capture_eth:canary', 'capture buffer still holds the canary -- the ADC DMA did not write'); end
end

function v = getf(s, f, d)
if isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
