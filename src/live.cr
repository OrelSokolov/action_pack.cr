# ActionController::Live — порт actionpack 8.1.4
# lib/action_controller/metal/live.rb (Iteration 9).
#
# Oracle: oracle/live_cases.rb → oracle/live_expected.yml (28 кейсов
# с настоящего actionpack 8.1.4 + puma 6.6.1), зеркало —
# railties.cr/spec/live_spec.cr.
#
# Семантика 1:1 с гемом:
# - response.stream.write/writeln — запись в буфер размером queue_size
#   (10 по умолчанию): заполненный буфер блокирует пишущий fiber —
#   backpressure; потребитель (pump в запросном fiber'е) освобождает
#   слоты (аналог SizedQueue);
# - первая запись коммитит заголовки: Cache-Control ||= no-cache,
#   Content-Length удаляется (Transfer-Encoding: chunked ставит
#   HTTP::Server автоматически);
# - close — конец потока (sentinel для pump); abort — потребитель
#   отвалился: буфер очищается, следующий И заблокированный write
#   поднимает ClientDisconnected — так отменяется fiber экшена при
#   disconnect клиента;
# - ignore_disconnect = true — молча отбрасывать вместо исключения;
# - on_error/call_on_error — хук ошибки после коммита;
# - ActionController::Live::SSE — wire-формат побайтово: опции в
#   порядке PERMITTED_OPTIONS (retry, event, id), data-строки с
#   продолжением на \n, не-строки JSON-кодируются;
# - send_stream(filename:, disposition:, type:) — заголовки CT/CD +
#   yield стрима, ensure close;
# - экшен исполняется в отдельном fiber'е (аналог
#   new_controller_thread): заголовки уходят при первом write
#   (аналог await_commit), исключение ДО коммита пробрасывается в
#   запросный fiber (→ 500 в лестнице ShowExceptions), ПОСЛЕ коммита —
#   call_on_error + close.
#
# Задокументированные отклонения от гема:
# - IOError Ruby ↔ IO::Error Crystal ("closed stream" при write после
#   close);
# - ActionView-фрагмент streaming_completion_on_exception при
#   исключении после коммита НЕ пишется — совпадает с наблюдаемым
#   поведением оригинала (оракул transport_error_after_commit_partial:
#   единственный фрейм "partial");
# - abort немедленно будит заблокированного продюсера (MRI SizedQueue
#   может держать поток в push) — отмена fiber'а без окон зависания;
# - response.stream есть у любого HTTP::Server::Response (класс открыт
#   расширением), но перекачивается только при
#   `include ActionController::Live` — без него записи никуда не идут;
# - SSE: id: 0 — валидный id (в Ruby 0 falsy и молча пропускается).

require "http/server"
require "sync/mutex"
require "sync/condition_variable"

# response.stream — как в Rails API (Live::Buffer у Response гема).
# Открывает stdlib-класс: только Live-контроллеры (include) качают
# стрим; поле-ивар ничего не стоит обычным ответам.
class HTTP::Server::Response
  @live_stream : ActionController::Live::Stream?

  def live_stream : ActionController::Live::Stream
    @live_stream ||= ActionController::Live::Stream.new(self)
  end

  # Не создаёт стрим (для проверок «есть ли уже Live-поток»).
  def live_stream? : ActionController::Live::Stream?
    @live_stream
  end

  def stream : ActionController::Live::Stream
    live_stream
  end
end

module ActionController
  module Live
    # RuntimeError (не IOError) — как в геме: то, что вне контроля
    # разработчика.
    class ClientDisconnected < RuntimeError
    end

    # Порт Live::Buffer: буфер с backpressure поверх SizedQueue(10).
    class Stream
      class_property queue_size : Int32 = 10

      getter response : HTTP::Server::Response

      @mutex : Sync::Mutex
      @has_data : Sync::ConditionVariable
      @has_space : Sync::ConditionVariable
      @buf = [] of String
      @closed = false   # close() — продюсер закончил
      @aborted = false  # abort() — потребитель отвалился
      @committed = false
      @error_callback : Proc(Nil)?
      @ignore_disconnect = false

      def initialize(@response : HTTP::Server::Response)
        @mutex = Sync::Mutex.new
        @has_data = Sync::ConditionVariable.new(@mutex)
        @has_space = Sync::ConditionVariable.new(@mutex)
      end

      property ignore_disconnect : Bool

      def ignore_disconnect? : Bool
        @ignore_disconnect
      end

      def write(string : String) : Int32
        commit! unless @committed

        produce(string)

        unless connected?
          clear_buffer
          raise ClientDisconnected.new("client disconnected") unless @ignore_disconnect
        end
        string.bytesize
      end

      # То же, что write, но с гарантированной \n на конце.
      def writeln(string : String) : Nil
        write(string.ends_with?('\n') ? string : string + "\n")
      end

      # Конец контента от продюсера; pump допивает буфер и завершает
      # ответ (терминатор chunked допишет HTTP::Server::Response#close).
      def close : Nil
        @mutex.lock
        @closed = true
        @has_data.broadcast
        @mutex.unlock
      end

      # Потребитель (клиент) больше не читает: очистить буфер и
      # отменить продюсера — заблокированный write и следующий write
      # поднимут ClientDisconnected.
      def abort : Nil
        @mutex.lock
        @aborted = true
        @buf.clear
        @has_data.broadcast
        @has_space.broadcast
        @mutex.unlock
      end

      # Клиент ещё на связи?
      def connected? : Bool
        !@aborted
      end

      # Заголовки уже ушли (первый write)?
      def committed? : Bool
        @committed
      end

      def on_error(&block : -> Nil) : Nil
        @error_callback = block
      end

      def call_on_error : Nil
        @error_callback.try(&.call)
      end

      # --- consumer side (pump, запросный fiber) ---

      # nil = конец (close-семантика) или abort.
      def pop : String?
        @mutex.lock
        begin
          while @buf.empty? && !@closed && !@aborted
            @has_data.wait
          end
          return nil if @aborted
          return nil if @buf.empty? # closed и опустошён
          chunk = @buf.shift
          @has_space.broadcast
          chunk
        ensure
          @mutex.unlock
        end
      end

      # Перекачка буфера в сокет: каждый write+flush = отдельный
      # chunk-фрейм. Ошибка сокета (клиент отключился) → abort →
      # отмена fiber'а экшена.
      def pump : Bool
        loop do
          chunk = pop
          break unless chunk
          @response.write(chunk.to_slice)
          @response.flush
        end
        true
      rescue ex : HTTP::Server::ClientError | IO::Error
        abort
        false
      end

      # --- internals ---

      private def clear_buffer : Nil
        @mutex.lock
        @buf.clear
        @mutex.unlock
      end

      private def commit! : Nil
        @response.headers["Cache-Control"] ||= "no-cache"
        @response.headers.delete("Content-Length")
        @committed = true
      end

      private def produce(string : String) : Nil
        @mutex.lock
        begin
          raise IO::Error.new("closed stream") if @closed
          while @buf.size >= self.class.queue_size && !@aborted && !@closed
            @has_space.wait # backpressure: ждём свободный слот
          end
          return if @aborted # данные отброшены; write поднимет ClientDisconnected
          raise IO::Error.new("closed stream") if @closed
          @buf.push(string)
          @has_data.signal
        ensure
          @mutex.unlock
        end
      end
    end

    # Порт ActionController::Live::SSE: пишем SSE-события в любой
    # объект с write(String)/close (стрим или фейка в спеках).
    class SSE(T)
      def initialize(@stream : T, event : String? = nil, id : Int32? = nil,
                     retry : Int32? = nil)
        @event = event
        @id = id
        @retry = retry
      end

      def close : Nil
        @stream.close
      end

      # String — как есть; прочее — JSON (ActiveSupport::JSON.encode
      # гема ↔ to_json — побайтово на простых значениях).
      def write(object : String | JSON::Any::Type,
                event : String? = nil, id : Int32? = nil, retry : Int32? = nil) : Nil
        data = object.is_a?(String) ? object : object.to_json

        r = retry || @retry
        e = event || @event
        i = id || @id

        io = IO::Memory.new
        io << "retry: " << r << "\n" if r
        io << "event: " << e << "\n" if e
        io << "id: " << i << "\n" if i
        message = data.gsub("\n", "\ndata: ")
        io << "data: " << message << "\n\n"
        @stream.write(io.to_s)
      end
    end

    # Экшен в отдельном fiber'е, pump — в запросном: заголовки уходят
    # на первом write (await_commit), тело стримится параллельно с
    # работой экшена. Исключение до коммита — наружу (500); после
    # коммита — call_on_error + close (аналог process в геме).
    def __live_dispatch(&block : -> Nil) : Nil
      stream = response.live_stream
      errors = [] of Exception

      spawn(name: "action_controller.live") do
        begin
          block.call
        rescue ex : Exception
          if stream.committed?
            begin
              stream.call_on_error
            rescue ex2 : Exception
              # проглатываем: ошибка в хуке не должна маскировать
              # исходную (гем логирует; логгера в action_pack нет)
            ensure
              stream.close
            end
          else
            errors << ex
            stream.close
          end
        else
          stream.close
        end
      end

      stream.pump

      raise errors[0] unless errors.empty?
    end

    # send_stream(filename: "subscribers.csv") do |stream|
    #   stream.write "email\n"
    # end
    def send_stream(filename : String, disposition : String = "attachment",
                    type : String? = nil) : Nil
      payload = {"filename" => filename, "disposition" => disposition,
                 "type" => type} of String => ActiveSupport::Any
      ActiveSupport::Notifications.instrument("send_stream.action_controller", payload) do
        response.headers["Content-Type"] =
          type || DataStreaming::MIME_BY_EXT[File.extname(filename).downcase.delete(".")]? ||
            DataStreaming::DEFAULT_SEND_FILE_TYPE
        response.headers["Content-Disposition"] =
          DataStreaming::ContentDisposition.format(disposition, filename)
        yield response.stream
      end
    ensure
      response.stream.close
    end
  end
end
