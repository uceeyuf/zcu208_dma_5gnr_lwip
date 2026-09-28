% demo_5gnr_loopback.m -- play a 100-MHz 5G NR downlink frame through the board and measure the PDSCH EVM.
%
% Requirements: MATLAB R2024a (tested) with 5G Toolbox, Signal Processing Toolbox and Instrument Control Toolbox
% (tcpclient). The NR helpers hNRReferenceWaveformGenerator and hNRDownlinkEVM ship with the MathWorks example
% "NR Waveform Capture and Analysis Using SDR"; this script opens that example once to put them on the path.
%
% Hardware: board booted with xsct/program_run.tcl, host NIC on 192.168.1.x, DAC Tile 228 ch0 cabled to
% ADC Tile 226 ch0 (directly or through the link under test). See README.md.
%
% Flow: DL-FRC-FR1-64QAM, 100 MHz, 30 kHz SCS, FDD, 10 ms at 122.88 MS/s -> 200 MS/s (625/384) -> padded to 2^21
% samples (one DMA cycle) at -6 dBFS peak -> play + capture over Ethernet -> cyclic alignment -> hNRDownlinkEVM.
clear; close all;
here = fileparts(mfilename('fullpath')); addpath(here);
if ~exist('hNRDownlinkEVM', 'file') || ~exist('hNRReferenceWaveformGenerator', 'file')
    exdir = fullfile(userpath, 'Examples', ['R' version('-release')], '5g', 'NRWaveformCaptureAndAnalysisWithSDRExample');
    if ~isfolder(exdir), openExample('5g/NRWaveformCaptureAndAnalysisWithSDRExample'); close all; end
    addpath(exdir);
end

%% ---- waveform ----
rc = "DL-FRC-FR1-64QAM"; Fs = 200e6;
gen = hNRReferenceWaveformGenerator(rc, "100MHz", "30kHz", "FDD");
cfgDL = gen.Config;
s = resample(gen.generateWaveform(), 625, 384);          % 122.88 -> 200 MS/s, 2,000,000 samples = 10 ms
Nfr = numel(s); cycle = 2^21;                             % DMA cycle: frame + zero gap (8 MB, a multiple of 4 KB)
tx = [s / max(abs(s)) * 10^(-6/20); zeros(cycle - Nfr, 1)];

%% ---- play + capture ----
[rx, info] = play_capture_eth(tx);
fprintf('upload %.1f s, capture read-back %.1f s, ADC peak %.1f dBFS\n', info.t_up_s, info.t_down_s, info.adc_peak_dBFS);
assert(~info.canary_untouched, 'the ADC DMA did not write the capture buffer');
assert(info.adc_peak_dBFS > -45, 'ADC peak %.1f dBFS: check the DAC-ADC cabling', info.adc_peak_dBFS);

%% ---- alignment: cyclic cross-correlation against the played cycle ----
rx1 = rx(1:cycle);
c = abs(ifft(fft(rx1) .* conj(fft(tx)))); [cPk, i0] = max(c);
fprintf('frame start at sample %d, correlation peak/median %.0f\n', i0, cPk/median(c));
rxFrame = [rx1; rx1]; rxFrame = rxFrame(i0 : i0 + Nfr - 1);

%% ---- EVM ----
cfg = struct('PlotEVM', false, 'DisplayEVM', false, 'Label', rc, 'SampleRate', Fs, 'IQImbalance', true, ...
             'TargetRNTIs', 0, 'CorrectCoarseFO', true, 'CorrectFineFO', true, 'ExcludeDC', true);
[evmInfo, eqSym] = hNRDownlinkEVM(cfgDL, rxFrame, cfg);
evm = evmInfo.PDSCH(1).OverallEVM.RMS * 100;
fprintf('PDSCH EVM (RMS) %.2f %%  (3GPP limit for 64QAM: 8 %%)\n', evm);

%% ---- figure ----
nf = 4096;
[ptx, f] = pwelch(s, hann(nf), nf/2, nf, Fs, 'centered');
prx = pwelch(rxFrame, hann(nf), nf/2, nf, Fs, 'centered');
ref = max(10*log10(prx));
figure('Color', 'w', 'Position', [100 100 1100 440]);
subplot(1, 2, 1);
plot(f/1e6, 10*log10(ptx) - max(10*log10(ptx)), 'Color', [0.6 0.6 0.6]); hold on;
plot(f/1e6, 10*log10(prx) - ref, 'Color', [0 0.35 0.7]); grid on; xlim([-100 100]); ylim([-80 5]);
xlabel('Frequency (MHz)'); ylabel('PSD (dB, normalized)'); legend('Transmitted', 'Captured', 'Location', 'south');
title(sprintf('Spectrum at %d MS/s', Fs/1e6));
subplot(1, 2, 2);
e = eqSym{1, 1}; e = e(1:max(1, floor(numel(e)/2e4)):end);
plot(real(e), imag(e), '.', 'MarkerSize', 2, 'Color', [0 0.35 0.7]); axis equal; grid on; xlim([-1.5 1.5]); ylim([-1.5 1.5]);
xlabel('In-phase'); ylabel('Quadrature'); title(sprintf('PDSCH 64QAM, EVM %.2f %%', evm));
sgtitle('ZCU208 5G NR loopback (DL-FRC-FR1-64QAM, 100 MHz)');
