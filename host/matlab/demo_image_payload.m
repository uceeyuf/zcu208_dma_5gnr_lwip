% demo_image_payload.m -- send an image as the PDSCH payload of a 100-MHz 5G NR frame through the board and decode it.
%
% Requirements: as demo_5gnr_loopback.m (5G Toolbox; the MathWorks NR helpers are put on the path from the example
% "NR Waveform Capture and Analysis Using SDR"), plus Image Processing Toolbox for imresize.
%
% Flow: peppers.png (shipped with MATLAB) scaled to a 256-pixel long side -> DL-SCH transport blocks of a
% DL-FRC-FR1-64QAM frame (img_make_waveform) -> 200 MS/s, one 2^21-sample DMA cycle at -6 dBFS peak -> play and
% capture over Ethernet -> frame alignment robust to the residual DAC/ADC frequency offset (img_align) -> PDSCH
% receiver and LDPC decoding (img_rx_decode) -> image. Pixels of slots whose CRC fails are painted grey.
clear; close all;
here = fileparts(mfilename('fullpath')); addpath(here);
if ~exist('hNRReferenceWaveformGenerator', 'file')
    exdir = fullfile(userpath, 'Examples', ['R' version('-release')], '5g', 'NRWaveformCaptureAndAnalysisWithSDRExample');
    if ~isfolder(exdir), openExample('5g/NRWaveformCaptureAndAnalysisWithSDRExample'); close all; end
    addpath(exdir);
end

M = img_make_waveform('peppers.png', '64QAM', struct('maxDim', 256));
cycle = 2^21;
tx = [M.wave200 / max(abs(M.wave200)) * 10^(-6/20); zeros(cycle - M.Nfr, 1)];

[rx, info] = play_capture_eth(tx);
fprintf('upload %.1f s, capture read-back %.1f s, ADC peak %.1f dBFS\n', info.t_up_s, info.t_down_s, info.adc_peak_dBFS);
assert(~info.canary_untouched, 'the ADC DMA did not write the capture buffer');

[rxFrame, A] = img_align(rx(1:cycle), M.wave200, M.Nfr);
fprintf('frame start at sample %d, correlation peak/median %.0f\n', A.off, A.pkMed);
D = img_rx_decode(rxFrame, M, struct('markErrors', true));
nS = numel(D.blkerr);
fprintf('%d/%d transport blocks pass CRC, payload BER %.2e, PSNR %.1f dB, EVM %.2f %%\n', ...
        nnz(~D.blkerr), nS, D.postBER, D.psnr, D.evm);

nf = 4096; Fs = 200e6;
[ptx, f] = pwelch(M.wave200, hann(nf), nf/2, nf, Fs, 'centered');
prx = pwelch(rxFrame, hann(nf), nf/2, nf, Fs, 'centered');
figure('Color', 'w', 'Position', [100 100 1100 820]);
subplot(2, 2, 1); imshow(M.srcImage); title('Transmitted image');
subplot(2, 2, 2); imshow(D.img);
if isinf(D.psnr), ps = 'error-free'; else, ps = sprintf('PSNR %.1f dB', D.psnr); end
title(sprintf('Received: %d/%d blocks CRC OK, %s', nnz(~D.blkerr), nS, ps));
subplot(2, 2, 3);
plot(f/1e6, 10*log10(ptx) - max(10*log10(ptx)), 'Color', [0.6 0.6 0.6]); hold on;
plot(f/1e6, 10*log10(prx) - max(10*log10(prx)), 'Color', [0 0.35 0.7]); grid on; xlim([-100 100]); ylim([-80 5]);
xlabel('Frequency (MHz)'); ylabel('PSD (dB, normalized)'); legend('Transmitted', 'Captured', 'Location', 'south');
title(sprintf('Spectrum at %d MS/s', Fs/1e6));
subplot(2, 2, 4); e = D.eqSym;
plot(real(e), imag(e), '.', 'MarkerSize', 1.5, 'Color', [0 0.35 0.7]); axis equal; grid on;
xlim([-1.5 1.5]); ylim([-1.5 1.5]); xlabel('In-phase'); ylabel('Quadrature');
title(sprintf('PDSCH 64QAM, EVM %.2f %%', D.evm));
sgtitle(sprintf('ZCU208 5G NR image payload (%dx%d pixels, %.0f kB in one 10-ms frame)', ...
        M.imgSize(1), M.imgSize(2), numel(M.srcImage)/1024));
