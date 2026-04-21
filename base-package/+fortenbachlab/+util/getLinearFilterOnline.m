function linearFilter = getLinearFilterOnline(stimulus, response, sampleRate, freqCutoff)
% GETLINEARFILTERONLINE  Compute linear temporal filter via reverse correlation.
%
%   linearFilter = getLinearFilterOnline(stimulus, response, sampleRate, freqCutoff)
%
%   Computes the linear filter relating stimulus to response using FFT-based
%   cross-spectral analysis. The filter is the one that, when convolved with
%   the stimulus, best predicts the response in a least-squares sense.
%
%   Inputs:
%       stimulus    - Row vector(s) of stimulus values (contrast or voltage).
%                     Multiple trials as rows of a matrix.
%       response    - Row vector(s) of response values (same size as stimulus).
%                     Multiple trials as rows of a matrix.
%       sampleRate  - Sample rate in Hz.
%       freqCutoff  - Frequency cutoff in Hz. Filter components above this
%                     frequency are zeroed. Should match the stimulus bandwidth.
%
%   Output:
%       linearFilter - The estimated linear filter (impulse response).
%
%   Algorithm:
%       F(filter) = <F(response) * conj(F(stimulus))> / <F(stimulus) * conj(F(stimulus))>
%
%   Based on Chichilnisky (2001) and the Rieke/Manookin lab implementations.

% Cross-spectral method in frequency domain.
filterFft = mean(fft(response, [], 2) .* conj(fft(stimulus, [], 2)), 1) ...
          ./ mean(fft(stimulus, [], 2) .* conj(fft(stimulus, [], 2)), 1);

% Apply frequency cutoff.
freqCutoffBin = round(freqCutoff / (sampleRate / size(stimulus, 2)));
filterFft(:, 1 + freqCutoffBin : size(stimulus, 2) - freqCutoffBin) = 0;

% Back to time domain.
linearFilter = real(ifft(filterFft));

end
