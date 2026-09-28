classdef RfsocEth < handle
% RfsocEth  1GbE client for the board server (vitis/src/net_server.c).
%
%   E = RfsocEth();                       % 192.168.1.10:7000 (defaults in net_server.h)
%   E.ping();                             % true if the board answers
%   E.write(hex2dec('40001000'), bytes);  % DAC waveform (uint8 vector) -> DDR
%   b = E.read(hex2dec('10001000'), n);   % ADC capture buffer -> uint8 vector
%   st = E.exec('rfdcReady');             % run a console command; 0 = XST_SUCCESS
%   E.cmd('dacPlay 8192');                % exec + error if the board rejects it
%
% Wire protocol (little-endian): header u32 magic|cmd|addr|len, then payload (WRITE/EXEC);
% reply u32 magic|status, followed by len bytes for READ. One request at a time.
% Replaces the xsct/JTAG 'dow -data' / 'mrd -bin' path (~1 MB/s) and, optionally, the UART.

    properties
        ip   = '192.168.1.10'
        port = 7000
        timeout = 60          % s; an 8 MB capture read-back must fit comfortably
    end
    properties (Access = private)
        t
    end
    properties (Constant)
        MAGIC = uint32(hex2dec('52464E54'))
        CMD_WRITE = uint32(1); CMD_READ = uint32(2); CMD_EXEC = uint32(3); CMD_PING = uint32(4);
    end

    methods
        function o = RfsocEth(ip, port, timeout)
            if nargin >= 1 && ~isempty(ip),   o.ip = ip;   end
            if nargin >= 2 && ~isempty(port), o.port = port; end
            if nargin >= 3 && ~isempty(timeout), o.timeout = timeout; end
            o.t = tcpclient(o.ip, o.port, 'Timeout', o.timeout, 'ConnectTimeout', 5);
        end
        function delete(o)
            % release the tcpclient so the socket closes (FIN) immediately
            try, o.t = []; catch, end
        end
        function ok = ping(o)
            ok = false;
            try
                o.send(o.CMD_PING, 0, 0, []);
                ok = (o.reply() == 0);
            catch
            end
        end
        function write(o, addr, bytes)
            % bytes: uint8 vector (use typecast(int16vec,'uint8') for I/Q streams)
            bytes = uint8(bytes(:)).';
            o.send(o.CMD_WRITE, addr, numel(bytes), bytes);
            st = o.reply();
            assert(st == 0, 'RfsocEth:write', 'board rejected WRITE 0x%08X len %d (status %d)', addr, numel(bytes), st);
        end
        function b = read(o, addr, n)
            o.send(o.CMD_READ, addr, n, []);
            st = o.reply();
            assert(st == 0, 'RfsocEth:read', 'board rejected READ 0x%08X len %d (status %d)', addr, n, st);
            b = uint8(read(o.t, n, 'uint8'));
            assert(numel(b) == n, 'RfsocEth:read', 'short read: %d of %d bytes', numel(b), n);
            b = b(:);
        end
        function st = exec(o, cmdline)
            cmdline = char(cmdline);
            o.send(o.CMD_EXEC, 0, numel(cmdline), uint8(cmdline));
            st = o.reply();
        end
        function cmd(o, cmdline)
            st = o.exec(cmdline);
            assert(st == 0, 'RfsocEth:cmd', ...
                'board rejected "%s" (status %d: unknown command / wrong arg count) — is the lwIP dpd.elf running?', ...
                char(cmdline), st);
        end
        function flush(o)
            if o.t.NumBytesAvailable > 0, read(o.t, o.t.NumBytesAvailable, 'uint8'); end
        end
    end

    methods (Access = private)
        function send(o, cmd, addr, len, payload)
            hdr = typecast(uint32([o.MAGIC, cmd, uint32(addr), uint32(len)]), 'uint8');
            if isempty(payload), write(o.t, hdr);
            else,                write(o.t, [hdr, uint8(payload(:)).']); end
        end
        function st = reply(o)
            r = uint8(read(o.t, 8, 'uint8'));
            assert(numel(r) == 8, 'RfsocEth:reply', 'no reply from board (timeout %g s)', o.timeout);
            w = typecast(r(:).', 'uint32');
            assert(w(1) == o.MAGIC, 'RfsocEth:reply', 'bad reply magic 0x%08X', w(1));
            st = double(w(2));
        end
    end
end
